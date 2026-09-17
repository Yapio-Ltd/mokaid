defmodule Mokaid.AI.Coordinator do
  @moduledoc "Conversational mission preparation. This endpoint never executes model-produced actions."
  import Ecto.Query
  alias Mokaid.{Agents, Repo}
  alias MokaidWeb.JSON, as: Serializer

  def stop(workspace_id, id, member) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        # Same lock as wave advancement: a completion cannot enqueue the next
        # wave between canceling the parent and its outstanding children.
        task =
          Repo.one(
            from t in Mokaid.Tasks.Task,
              where: t.workspace_id == ^workspace_id and t.id == ^id,
              lock: "FOR UPDATE"
          )

        if task == nil, do: Repo.rollback(:not_found)

        if task.status not in ["completed", "canceled"] do
          children =
            Repo.all(
              from t in Mokaid.Tasks.Task,
                where:
                  t.workspace_id == ^workspace_id and
                    fragment("?->>'composite_parent_id' = ?", t.metadata, ^id)
            )

          outstanding =
            Enum.reject(children, &(&1.status in ["completed", "in_review", "canceled"]))

          ids = [task.id | Enum.map(outstanding, & &1.id)]
          # Reserve the entire cancellation before freeing an agent; its queue
          # must not start a sibling while this transaction is stopping them.
          Repo.update_all(
            from(t in Mokaid.Tasks.Task, where: t.workspace_id == ^workspace_id and t.id in ^ids),
            set: [status: "canceled"]
          )

          {:ok, _} = Mokaid.Tasks.update_task(task, %{"status" => "canceled"}, member)

          for child <- outstanding do
            {:ok, _} = Mokaid.Tasks.update_task(child, %{"status" => "canceled"}, member)
          end
        end

        Mokaid.Tasks.get_task(workspace_id, id)
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  def missions(workspace_id) do
    runs =
      from r in Mokaid.Tasks.TaskExecutionRun,
        distinct: r.task_id,
        order_by: [asc: r.task_id, desc: r.inserted_at]

    outputs =
      from d in Mokaid.Drive.DriveItem,
        where: d.status == "active",
        order_by: [asc: d.inserted_at]

    approvals =
      from a in Mokaid.Tasks.TaskApprovalRequest,
        where: a.status == "pending",
        order_by: [desc: a.inserted_at]

    Repo.all(
      from t in Mokaid.Tasks.Task,
        where: t.workspace_id == ^workspace_id,
        order_by: [desc: t.updated_at],
        limit: 50,
        preload: [
          :project,
          :assigned_agent,
          :subtasks,
          execution_runs: ^runs,
          drive_items: ^outputs,
          approval_requests: ^approvals
        ]
    )
    |> Enum.map(&Serializer.task/1)
  end

  def normalize_request(params) do
    with message when is_binary(message) <- params["message"],
         true <-
           String.trim(message) != "" and byte_size(message) <= 48_000 and
             String.length(message) <= 12_000,
         history when is_list(history) <- Map.get(params, "conversation", []) do
      history =
        history
        |> Enum.take(-24)
        |> Enum.flat_map(fn
          %{"role" => role, "body" => body}
          when role in ["user", "assistant"] and is_binary(body) ->
            [%{role: role, body: String.slice(body, 0, 8_000)}]

          _ ->
            []
        end)

      language =
        if is_binary(params["language"]), do: String.slice(params["language"], 0, 32), else: ""

      {:ok, %{message: String.trim(message), conversation: history, language: language}}
    else
      _ -> {:error, :invalid_request}
    end
  end

  # Workspace, agent and task identities always come from the authenticated
  # server context. The client cannot supply another workspace's snapshot.
  def context(workspace_id, request) do
    agents =
      Agents.list_agents(workspace_id)
      |> Enum.reject(&(&1.kind == "human_linked" or &1.status in ["archived", "disabled"]))
      |> Enum.take(60)
      |> Enum.map(
        &%{
          id: &1.id,
          name: &1.display_name,
          role: &1.role_title,
          status: &1.status,
          skills: &1.skills
        }
      )

    tasks =
      missions(workspace_id)
      |> Enum.take(30)
      |> Enum.map(fn task ->
        Map.take(task, [
          :id,
          :title,
          :status,
          :assigned_agent_name,
          :progress_percent,
          :attachments,
          :pending_approval,
          :composite,
          :composite_parent_id
        ])
        |> Map.put(:latest_run, task.latest_run && Map.take(task.latest_run, [:status, :error]))
      end)

    Map.merge(request, %{agents: agents, missions: tasks})
  end

  def reply(workspace_id, member, params) do
    with {:ok, request} <- normalize_request(params),
         :ok <- authorize_credits(workspace_id),
         {:ok, result} <- ask_worker(context(workspace_id, request)) do
      cost = if is_integer(result["cost_cents"]), do: max(result["cost_cents"], 0), else: 0

      Mokaid.Billing.record_usage(
        workspace_id,
        "member",
        member.id,
        "orchestrator_chat",
        1,
        "turn",
        cost_cents: cost,
        metadata: %{token_usage: result["usage"] || %{}}
      )

      if cost > 0,
        do:
          Mokaid.Billing.Credits.charge_run(workspace_id, nil, nil, cost,
            description: "Moked orchestrator conversation"
          )

      {:ok, Map.take(result, ["reply", "language", "mission_instruction", "task_id"])}
    end
  end

  defp authorize_credits(workspace_id) do
    if Mokaid.Billing.Credits.can_start_task?(workspace_id),
      do: :ok,
      else: {:error, :insufficient_credits}
  end

  defp ask_worker(payload) do
    config = Application.fetch_env!(:mokaid, :ai_worker)

    # Mission execution uses SQS in production, but conversational replies need
    # the worker's synchronous HTTP endpoint. Do not route chat through the
    # mission queue or require changing that queue's dispatch configuration.
    if Mokaid.AI.WorkerClient.absolute_url?(config[:url]) and
         is_binary(config[:token]) and String.trim(config[:token]) != "" do
      case Req.post(
             url: String.trim_trailing(config[:url], "/") <> "/orchestrator/chat",
             json: payload,
             headers: [{"authorization", "Bearer #{config[:token]}"}],
             receive_timeout: 25_000,
             retry: false
           ) do
        {:ok, %{status: 200, body: %{"reply" => text} = result}}
        when is_binary(text) and text != "" ->
          {:ok, result}

        _ ->
          {:error, :orchestrator_unavailable}
      end
    else
      {:error, :orchestrator_unavailable}
    end
  end
end
