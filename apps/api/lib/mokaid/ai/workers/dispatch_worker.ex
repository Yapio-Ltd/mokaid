defmodule Mokaid.AI.Workers.DispatchWorker do
  @moduledoc """
  Dispatches an AI run to the Python worker. Uses SQS in production
  and direct HTTP in development.
  """

  use Oban.Worker, queue: :ai_dispatch, max_attempts: 5

  alias Mokaid.Tasks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
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

        payload = %{
          run_id: run.id,
          workspace_id: run.workspace_id,
          agent_id: run.agent_id,
          task_id: run.task_id,
          task_title: task && task.title,
          task_description: task && task.description,
          input: run.input,
          mcp_servers: mcp_servers
        }

        dispatch(config[:dispatch], payload, config)
    end
  end

  defp dispatch(:http, payload, config) do
    case Req.post(
           url: "#{config[:url]}/runs",
           json: payload,
           headers: [{"authorization", "Bearer #{config[:token]}"}],
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, "worker returned #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp dispatch(:sqs, payload, config) do
    config[:sqs_queue_url]
    |> ExAws.SQS.send_message(Jason.encode!(payload))
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
