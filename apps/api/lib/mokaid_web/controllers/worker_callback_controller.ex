defmodule MokaidWeb.WorkerCallbackController do
  use MokaidWeb, :controller

  alias Mokaid.AI

  def progress(conn, %{"run_id" => run_id} = params) do
    with {:ok, run} <- AI.handle_progress(run_id, Map.drop(params, ["run_id"])) do
      json(conn, %{data: %{run_id: run.id, status: run.status}})
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
end
