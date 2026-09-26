defmodule MokaidWeb.WorkerTaskFollowupController do
  use MokaidWeb, :controller

  def create(conn, %{"workspace_id" => workspace_id, "id" => task_id} = params) do
    case Mokaid.AI.TaskFollowup.apply(workspace_id, task_id, params) do
      {:ok, result} -> json(conn, %{data: result})
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      {:error, :forbidden} -> error(conn, :forbidden, "forbidden")
      {:error, _} -> error(conn, :unprocessable_entity, "invalid_followup")
    end
  end

  def create(conn, _), do: error(conn, :unprocessable_entity, "invalid_followup")

  defp error(conn, status, code),
    do: conn |> put_status(status) |> json(%{error: %{code: code}})
end
