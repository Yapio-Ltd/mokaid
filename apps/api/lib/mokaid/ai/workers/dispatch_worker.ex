defmodule Mokaid.AI.Workers.DispatchWorker do
  @moduledoc """
  Dispatches an AI run to the Python worker. Uses SQS in production
  and direct HTTP in development.

  After max_attempts failures the job is discarded and we call
  `cleanup_failed_run/1` to mark the run as failed and release the agent,
  so neither the task nor the agent stay stuck indefinitely.
  """

  use Oban.Worker, queue: :ai_dispatch, max_attempts: 5

  alias Mokaid.Agents
  alias Mokaid.Realtime
  alias Mokaid.Tasks

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"run_id" => run_id},
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    config = Application.fetch_env!(:mokaid, :ai_worker)

    case Tasks.get_run(run_id) do
      nil ->
        {:cancel, :run_not_found}

      run ->
        task = Tasks.get_task(run.workspace_id, run.task_id)

        # MCP servers this agent is explicitly allowed to use (permission
        # matrix), with decrypted credentials for the worker's MCP client.
        mcp_servers =
          if run.agent_id do
            Mokaid.MCP.authorized_servers_for_agent(run.workspace_id, run.agent_id)
          else
            []
          end

        # Everything currently linked to the task (initial drops, files added
        # later in the thread, previous agent outputs), resolved to presigned
        # URLs so the worker can actually read their content.
        attached_files =
          if task do
            Mokaid.AI.Dispatcher.task_files(
              run.workspace_id,
              task.id,
              task.metadata["drive_item_ids"] || run.input["drive_item_ids"] || []
            )
          else
            Mokaid.AI.Dispatcher.attached_files(
              run.workspace_id,
              run.input["drive_item_ids"] || []
            )
          end

        agent = run.agent_id && Agents.get_agent(run.workspace_id, run.agent_id)

        payload = %{
          run_id: run.id,
          workspace_id: run.workspace_id,
          agent_id: run.agent_id,
          task_id: run.task_id,
          project_id: task && task.project_id,
          task_title: task && task.title,
          task_description: task && task.description,
          task_priority: task && task.priority,
          task_due_at: task && task.due_at,
          input: run.input,
          attached_files: attached_files,
          mcp_servers: mcp_servers,
          # Persona for the deep agent + colleagues it may consult.
          agent: agent_persona(agent),
          colleagues: colleagues(run.workspace_id, run.agent_id)
        }

        result = dispatch(config[:dispatch], payload, config)

        # On the final attempt clean up the run and unblock the agent.
        if result != :ok and attempt >= max_attempts do
          cleanup_failed_run(run, "AI worker unreachable after #{max_attempts} attempts")
        end

        result
    end
  end

  defp agent_persona(nil), do: %{}

  defp agent_persona(agent) do
    caps = agent.capabilities || %{}
    learning = Map.get(caps, "learning", %{})
    domain_pack = Map.get(caps, "domain_pack", %{})

    %{
      display_name: agent.display_name,
      role_title: agent.role_title,
      department: agent.department,
      skills: skill_names(agent.skills),
      knowledge_brief: Map.get(caps, "knowledge_brief"),
      archetype: Map.get(learning, "archetype") || Map.get(domain_pack, "archetype"),
      tier: Map.get(learning, "tier") || Map.get(domain_pack, "tier"),
      domain_skill_index: Map.get(domain_pack, "skill_index", []),
      suggested_mcp: Map.get(domain_pack, "suggested_mcp") || [],
      level: agent.level
    }
  end

  # Other AI employees of the workspace (excluding the running one) that the
  # deep agent may consult; the manager, when set, is listed first.
  defp colleagues(workspace_id, agent_id) do
    workspace_id
    |> Agents.list_agents(%{"kind" => "ai"})
    |> Enum.reject(&(&1.id == agent_id or not &1.ai_enabled))
    |> Enum.sort_by(&if(&1.manager_agent_id == nil, do: 0, else: 1))
    |> Enum.take(8)
    |> Enum.map(fn colleague ->
      %{
        id: colleague.id,
        name: colleague.display_name,
        role_title: colleague.role_title,
        department: colleague.department,
        skills: skill_names(colleague.skills)
      }
    end)
  end

  defp skill_names(skills) when is_list(skills) do
    Enum.map(skills, fn
      %{"name" => name} -> name
      skill when is_binary(skill) -> skill
      other -> inspect(other)
    end)
  end

  defp skill_names(_), do: []

  defp dispatch(:http, payload, config) do
    url = config[:url]

    if blank?(url) or not String.contains?(to_string(url), "://") do
      {:error, "ai_worker_url_missing"}
    else
      case Req.post(
             url: "#{url}/runs",
             json: payload,
             headers: [{"authorization", "Bearer #{config[:token]}"}],
             retry: false
           ) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status}} -> {:error, "worker returned #{status}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  # Test/offline environments: the run is recorded but nothing is dispatched.
  defp dispatch(:none, _payload, _config), do: :ok

  defp dispatch(:sqs, payload, config) do
    config[:sqs_queue_url]
    |> ExAws.SQS.send_message(Jason.encode!(payload))
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp cleanup_failed_run(run, error_message) do
    Tasks.update_run_progress(run, %{"status" => "failed", "error" => error_message})

    if run.agent_id do
      case Agents.get_agent(run.workspace_id, run.agent_id) do
        nil -> :ok
        agent -> Agents.change_status(agent, "idle", reason: "dispatch_failed")
      end
    end

    Realtime.broadcast_workspace(run.workspace_id, "task.progress_changed", %{
      task_id: run.task_id,
      run_id: run.id,
      status: "failed",
      error: error_message,
      agent_id: run.agent_id
    })
  end
end
