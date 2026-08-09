defmodule MokaidWeb.WorkerCallbackController do
  use MokaidWeb, :controller

  alias Mokaid.AI

  def progress(conn, %{"run_id" => run_id} = params) do
    with {:ok, run} <- AI.handle_progress(run_id, Map.drop(params, ["run_id"])) do
      json(conn, %{data: %{run_id: run.id, status: run.status}})
    end
  end

  def tool_activity(conn, %{"run_id" => run_id} = params) do
    event = params["event"] || Map.drop(params, ["run_id"])

    with {:ok, run} <- AI.handle_tool_activity(run_id, event) do
      json(conn, %{data: %{run_id: run.id}})
    end
  end

  def approval_request(conn, %{"run_id" => run_id} = params) do
    with {:ok, request} <- AI.handle_approval_request(run_id, Map.drop(params, ["run_id"])) do
      conn
      |> put_status(:created)
      |> json(%{data: %{approval_request_id: request.id, status: request.status}})
    end
  end

  def complete(conn, %{"run_id" => run_id} = params) do
    with {:ok, run} <-
           AI.handle_completion(
             run_id,
             params["output"] || %{},
             params["token_usage"] || %{},
             params["cost_cents"] || 0
           ) do
      json(conn, %{data: %{run_id: run.id, status: run.status}})
    end
  end

  def fail(conn, %{"run_id" => run_id} = params) do
    with {:ok, run} <- AI.handle_failure(run_id, params["error"] || "unknown error") do
      json(conn, %{data: %{run_id: run.id, status: run.status}})
    end
  end

  # LLM usage outside of runs (chat replies, knowledge indexing). Whitelisted
  # so the worker cannot invent arbitrary event types.
  @usage_sources %{
    "converse" => {"ai_converse", "message", "Agent reply in task thread"},
    "agent_chat" => {"ai_agent_chat", "message", "Direct chat reply"},
    "knowledge_ingest" => {"ai_ingest", "document", "Knowledge indexing"}
  }

  @doc """
  Meters (and charges in AI credits) LLM usage that happens outside of a
  mission run: conversational replies in task threads, direct agent chat,
  and knowledge-ingestion embeddings.
  """
  def usage(conn, %{"workspace_id" => workspace_id, "source" => source} = params) do
    case @usage_sources[source] do
      nil ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "unknown_usage_source", message: "Unknown source #{source}"}})

      {event_type, unit, description} ->
        cost_cents = if is_integer(params["cost_cents"]), do: params["cost_cents"], else: 0
        agent_id = params["agent_id"]
        token_usage = params["token_usage"] || %{}

        Mokaid.Billing.record_usage(workspace_id, "agent", agent_id, event_type, 1, unit,
          cost_cents: cost_cents,
          metadata:
            Map.take(token_usage, ["prompt_tokens", "completion_tokens", "total_tokens", "images"])
        )

        if cost_cents > 0 do
          Mokaid.Billing.Credits.charge_run(workspace_id, nil, agent_id, cost_cents,
            description: description
          )
        end

        json(conn, %{data: %{ok: true}})
    end
  end
end
