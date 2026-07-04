defmodule Mokaid.Tasks.Workers.OverdueTaskWorker do
  @moduledoc "Marks past-due open tasks as overdue and broadcasts the change."

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Mokaid.Realtime
  alias Mokaid.Repo
  alias Mokaid.Tasks.Task

  @open_statuses ~w(to_do in_progress in_review waiting)

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    overdue =
      Repo.all(
        from t in Task,
          where: t.status in ^@open_statuses and not is_nil(t.due_at) and t.due_at < ^now
      )

    Enum.each(overdue, fn task ->
      task
      |> Ecto.Changeset.change(status: "overdue")
      |> Repo.update()
      |> case do
        {:ok, updated} ->
          Realtime.broadcast_workspace(task.workspace_id, "task.status_changed", %{
            task_id: updated.id,
            status: "overdue",
            progress_percent: updated.progress_percent,
            assigned_agent_id: updated.assigned_agent_id
          })

        _ ->
          :ok
      end
    end)

    :ok
  end
end
