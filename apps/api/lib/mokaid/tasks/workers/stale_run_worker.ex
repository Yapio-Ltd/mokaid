defmodule Mokaid.Tasks.Workers.StaleRunWorker do
  @moduledoc """
  Fails AI runs that stopped making progress so tasks and agents never stay
  stuck forever:

    * `queued` / `running` runs with no update for #{15} minutes — the worker
      died or never picked them up;
    * `waiting_for_approval` runs that have no pending approval request —
      nothing exists for a human to decide on, so nobody can ever unblock them.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Mokaid.Agents
  alias Mokaid.Realtime
  alias Mokaid.Repo
  alias Mokaid.Tasks
  alias Mokaid.Tasks.TaskApprovalRequest
  alias Mokaid.Tasks.TaskExecutionRun

  @stale_after_minutes 15

  @impl Oban.Worker
  def perform(_job) do
    resume_pdf_exports()
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_minutes * 60, :second)

    stalled =
      Repo.all(
        from r in TaskExecutionRun,
          where: r.status in ["queued", "running"] and r.updated_at < ^cutoff
      )

    orphaned_waiting =
      Repo.all(
        from r in TaskExecutionRun,
          left_join: a in TaskApprovalRequest,
          on: a.run_id == r.id and a.status == "pending",
          where: r.status == "waiting_for_approval" and r.updated_at < ^cutoff and is_nil(a.id)
      )

    Enum.each(
      stalled,
      &fail_run(&1, "Run stalled: no progress for #{@stale_after_minutes} minutes.")
    )

    Enum.each(
      orphaned_waiting,
      &fail_run(&1, "Run was waiting for an approval request that was never created.")
    )

    :ok
  end

  @doc "Unblocks PDF exports paused by the old missing internal-tool risk classification."
  def resume_pdf_exports do
    # Leave time for a worker that just posted its callback to register its
    # waiting event. This only repairs existing PDF pauses, never external tools.
    cutoff = DateTime.add(DateTime.utc_now(), -5, :second)

    requests =
      Repo.all(
        from a in TaskApprovalRequest,
          join: r in TaskExecutionRun,
          on: a.run_id == r.id,
          join: t in Mokaid.Tasks.Task,
          on: t.id == r.task_id,
          where:
            a.status == "pending" and a.tool_name == "export_pdf" and
              a.inserted_at < ^cutoff and r.status == "waiting_for_approval" and
              t.status in ["waiting", "in_progress"],
          order_by: [asc: a.inserted_at],
          limit: 100
      )

    Enum.each(requests, &resume_pdf_export/1)
    :ok
  end

  @doc false
  def resume_pdf_export(request) do
    claimed =
      Repo.transaction(fn ->
        # Feedback takes the same task lock. Re-read both task and run under
        # it so a stale sweep snapshot can never resurrect stopped work.
        task =
          Repo.one(
            from t in Mokaid.Tasks.Task,
              where: t.id == ^request.task_id and t.status in ["waiting", "in_progress"],
              lock: "FOR UPDATE"
          )

        if task == nil, do: Repo.rollback(:no_longer_waiting)

        run =
          Repo.one(
            from r in TaskExecutionRun,
              where: r.id == ^request.run_id and r.status == "waiting_for_approval",
              lock: "FOR UPDATE"
          )

        if run == nil, do: Repo.rollback(:no_longer_waiting)
        now = DateTime.utc_now()

        {count, _} =
          Repo.update_all(
            from(a in TaskApprovalRequest,
              where: a.id == ^request.id and a.status == "pending" and a.tool_name == "export_pdf"
            ),
            set: [
              status: "approved",
              reviewed_at: now,
              updated_at: now,
              decision_payload: %{"source" => "internal_pdf_export_recovery"}
            ]
          )

        if count != 1, do: Repo.rollback(:no_longer_waiting)
        Mokaid.AI.handle_progress(run.id, %{"status" => "running"})
        run.id
      end)

    case claimed do
      {:ok, run_id} -> Mokaid.AI.resume_after_approval(run_id, "approved", nil, "export_pdf")
      {:error, :no_longer_waiting} -> :ok
    end
  end

  defp fail_run(run, reason) do
    Tasks.update_run_progress(run, %{"status" => "failed", "error" => reason})

    if run.agent_id do
      case Agents.get_agent(run.workspace_id, run.agent_id) do
        nil -> :ok
        agent -> Agents.change_status(agent, "idle", reason: "stale_run")
      end
    end

    task = Tasks.get_task(run.workspace_id, run.task_id)

    if task && task.status in ["waiting", "in_progress"] do
      Tasks.update_task(task, %{"status" => "to_do", "progress_percent" => 0})
    end

    Realtime.broadcast_workspace(run.workspace_id, "task.progress_changed", %{
      task_id: run.task_id,
      run_id: run.id,
      status: "failed",
      error: reason,
      agent_id: run.agent_id
    })

    # A dead run must not block the agent's queue.
    Mokaid.AI.dispatch_next(run.workspace_id, run.agent_id)
  end
end
