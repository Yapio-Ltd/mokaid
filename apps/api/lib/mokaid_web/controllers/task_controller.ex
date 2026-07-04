defmodule MokaidWeb.TaskController do
  use MokaidWeb, :controller

  alias Mokaid.AI
  alias Mokaid.Audit
  alias Mokaid.Tasks
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "tasks.view") do
      tasks = Tasks.list_tasks(workspace_id(conn), params)
      counts = Tasks.counts_by_status(workspace_id(conn))
      completed_today = Tasks.completed_today_count(workspace_id(conn))

      json(conn, %{
        data: Enum.map(tasks, &Serializer.task/1),
        meta: %{counts: counts, completed_today: completed_today}
      })
    end
  end

  def create(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "tasks.create"),
         {:ok, task} <- Tasks.create_task(workspace_id(conn), params, current_member(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.task(task)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "tasks.view"),
         %{} = task <- Tasks.get_task(workspace_id(conn), id) do
      json(conn, %{data: Serializer.task(task)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "tasks.update"),
         %{} = task <- Tasks.get_task(workspace_id(conn), id),
         {:ok, updated} <- Tasks.update_task(task, params, current_member(conn)) do
      json(conn, %{data: Serializer.task(updated)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "tasks.delete"),
         %{} = task <- Tasks.get_task(workspace_id(conn), id),
         {:ok, _} <- Tasks.delete_task(task) do
      json(conn, %{ok: true})
    end
  end

  def create_comment(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "tasks.view"),
         %{} = task <- Tasks.get_task(workspace_id(conn), id),
         {:ok, comment} <- Tasks.create_comment(task, params, current_member(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.comment(comment)})
    end
  end

  def execute_ai(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.run_ai"),
         %{} = task <- Tasks.get_task(workspace_id(conn), id),
         {:ok, run} <- AI.start_run(task, params["input"] || %{}) do
      Audit.log(workspace_id(conn), current_member(conn), "ai.run_started", "task", id, %{
        run_id: run.id
      })

      conn
      |> put_status(:created)
      |> json(%{data: %{run_id: run.id, status: run.status}})
    end
  end

  def approve_action(conn, %{"id" => id, "approval_request_id" => request_id} = params) do
    decision = params["decision"] || "approved"

    with :ok <- Permissions.authorize(current_member(conn), "tasks.approve_action"),
         %{} = _task <- Tasks.get_task(workspace_id(conn), id),
         %{} = request <- Tasks.get_approval_request(workspace_id(conn), request_id),
         {:ok, updated} <-
           Tasks.decide_approval(request, decision, current_member(conn), params["payload"]) do
      Audit.log(workspace_id(conn), current_member(conn), "task.approval_decided", "task", id, %{
        approval_request_id: request_id,
        decision: decision
      })

      if updated.run_id do
        AI.resume_after_approval(updated.run_id, decision)
      end

      json(conn, %{data: %{id: updated.id, status: updated.status}})
    end
  end
end
