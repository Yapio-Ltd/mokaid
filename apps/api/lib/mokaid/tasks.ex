defmodule Mokaid.Tasks do
  @moduledoc "Tasks, subtasks, comments, approvals and AI execution runs."

  import Ecto.Query

  alias Mokaid.Agents
  alias Mokaid.Agents.SkillLearning
  alias Mokaid.Realtime
  alias Mokaid.Repo

  alias Mokaid.Tasks.{
    Subtask,
    Task,
    TaskActivityEvent,
    TaskApprovalRequest,
    TaskComment,
    TaskExecutionRun
  }

  @preloads [
    :project,
    :assigned_agent,
    :subtasks,
    assigned_member: :user,
    comments: [author_member: :user, author_agent: []]
  ]

  def get_task(workspace_id, id) do
    Repo.one(
      from t in Task,
        where: t.workspace_id == ^workspace_id and t.id == ^id,
        preload: ^detail_preloads()
    )
  end

  # Detail view also carries linked drive files (inputs + agent outputs),
  # execution runs (latest first) and pending approval requests so the UI
  # can show the agent's result and ask for human decisions.
  defp detail_preloads do
    drive_items_query =
      from d in Mokaid.Drive.DriveItem,
        where: d.status == "active",
        order_by: [asc: d.inserted_at]

    runs_query = from r in TaskExecutionRun, order_by: [desc: r.inserted_at]

    approvals_query =
      from a in TaskApprovalRequest,
        where: a.status == "pending",
        order_by: [desc: a.inserted_at]

    [
      drive_items: drive_items_query,
      execution_runs: runs_query,
      approval_requests: approvals_query
    ] ++ @preloads
  end

  def list_tasks(workspace_id, filters \\ %{}) do
    # Preload only the latest execution run per task (DISTINCT ON task_id,
    # ordered by inserted_at DESC) so the dashboard can show run status
    # (queued / running / failed) without loading the full run history.
    latest_run_query =
      from r in TaskExecutionRun,
        distinct: r.task_id,
        order_by: [asc: r.task_id, desc: r.inserted_at]

    from(t in Task,
      where: t.workspace_id == ^workspace_id,
      preload: [:project, :assigned_agent, :subtasks, execution_runs: ^latest_run_query],
      order_by: [asc: t.position, desc: t.inserted_at]
    )
    |> maybe_filter(:status, filters["status"])
    |> maybe_filter(:priority, filters["priority"])
    |> maybe_filter(:project_id, filters["project_id"])
    |> maybe_filter(:assigned_agent_id, filters["agent_id"])
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [t], field(t, ^field) == ^value)

  def create_task(workspace_id, attrs, created_by \\ nil) do
    result =
      %Task{}
      |> Task.changeset(
        Map.merge(attrs, %{
          "workspace_id" => workspace_id,
          "created_by_member_id" => created_by && created_by.id
        })
      )
      |> Repo.insert()

    with {:ok, task} <- result do
      record_activity(task, created_by, "task.created")
      task = Repo.preload(task, @preloads)
      agent = loaded_assoc(task.assigned_agent)

      Realtime.broadcast_workspace(workspace_id, "task.created", %{
        task_id: task.id,
        title: task.title,
        project_id: task.project_id,
        assigned_agent_id: task.assigned_agent_id,
        assigned_agent_name: agent && agent.display_name
      })

      {:ok, task}
    end
  end

  defp loaded_assoc(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded_assoc(other), do: other

  def update_task(%Task{} = task, attrs, actor \\ nil) do
    old_status = task.status
    old_agent_id = task.assigned_agent_id

    result =
      task
      |> Task.changeset(Map.put(attrs, "workspace_id", task.workspace_id))
      |> Repo.update()

    with {:ok, updated} <- result do
      cond do
        updated.status != old_status ->
          record_activity(updated, actor, "task.status_changed", %{
            from: old_status,
            to: updated.status
          })

          Realtime.broadcast_workspace(task.workspace_id, "task.status_changed", %{
            task_id: updated.id,
            title: updated.title,
            status: updated.status,
            from_status: old_status,
            progress_percent: updated.progress_percent,
            assigned_agent_id: updated.assigned_agent_id
          })

          if updated.status == "completed" do
            Realtime.broadcast_workspace(task.workspace_id, "task.completed", %{
              task_id: updated.id,
              title: updated.title
            })

            maybe_celebrate_agent(updated)
            maybe_record_learning(updated)
          end

        true ->
          Realtime.broadcast_workspace(task.workspace_id, "task.updated", %{
            task_id: updated.id
          })
      end

      sync_ai_with_pipeline(updated, old_status, old_agent_id)

      {:ok, Repo.preload(updated, @preloads, force: true)}
    end
  end

  # The pipeline drives the agents: moving a task changes what its agent is
  # actually doing. Reassigning stops the previous agent; dragging out of
  # "in progress" cancels the run; dragging into it starts one. Guards in
  # Mokaid.AI (active-run checks) make these hooks safe to call from the AI
  # callbacks themselves without recursion.
  defp sync_ai_with_pipeline(%Task{} = updated, old_status, old_agent_id) do
    status = updated.status
    agent_changed = old_agent_id != updated.assigned_agent_id

    cond do
      agent_changed ->
        Mokaid.AI.cancel_active_runs_for_task(updated, "Task reassigned")

        if status == "in_progress" do
          Mokaid.AI.ensure_started(updated)
        end

      status != old_status and status in ["completed", "canceled", "to_do", "blocked"] ->
        Mokaid.AI.cancel_active_runs_for_task(updated, "Task moved to #{status}")

      status != old_status and status == "in_progress" ->
        Mokaid.AI.ensure_started(updated)

      true ->
        :ok
    end
  end

  defp maybe_celebrate_agent(%Task{assigned_agent_id: nil}), do: :ok

  defp maybe_celebrate_agent(%Task{} = task) do
    case Agents.get_agent(task.workspace_id, task.assigned_agent_id) do
      nil -> :ok
      agent -> Agents.change_status(agent, "idle", reason: "task_completed")
    end
  end

  defp maybe_record_learning(%Task{assigned_agent_id: nil}), do: :ok

  defp maybe_record_learning(%Task{} = task) do
    case Agents.get_agent(task.workspace_id, task.assigned_agent_id) do
      nil -> :ok
      agent -> SkillLearning.record_mission(agent, task, %{})
    end
  end

  def delete_task(%Task{} = task) do
    # Free the agent first: abort the live run and start its next mission.
    Mokaid.AI.cancel_active_runs_for_task(task, "Task deleted")
    Repo.delete(task)
  end

  def assign_task(%Task{} = task, agent_id, actor \\ nil) do
    with %{} = agent <- Agents.get_agent(task.workspace_id, agent_id),
         {:ok, updated} <-
           task
           |> Ecto.Changeset.change(assigned_agent_id: agent.id)
           |> Repo.update() do
      record_activity(updated, actor, "task.assigned", %{agent_id: agent.id})

      Realtime.broadcast_workspace(task.workspace_id, "task.assigned", %{
        task_id: task.id,
        assigned_agent_id: agent.id
      })

      Agents.change_status(agent, "busy", current_task_id: task.id, reason: "task_assigned")

      if agent.linked_member_id do
        Mokaid.Notifications.notify_member(
          task.workspace_id,
          agent.linked_member_id,
          "task_assigned",
          "New task assigned: #{task.title}",
          resource_type: "task",
          resource_id: task.id
        )
      end

      {:ok, Repo.preload(updated, @preloads, force: true)}
    else
      nil -> {:error, :agent_not_found}
      error -> error
    end
  end

  ## ---------- Subtasks & comments ----------

  def create_subtask(%Task{} = task, attrs) do
    %Subtask{}
    |> Subtask.changeset(
      Map.merge(attrs, %{"workspace_id" => task.workspace_id, "task_id" => task.id})
    )
    |> Repo.insert()
  end

  def get_subtask(%Task{} = task, subtask_id) do
    Repo.one(from s in Subtask, where: s.task_id == ^task.id and s.id == ^subtask_id)
  end

  def update_subtask(%Subtask{} = subtask, attrs) do
    result =
      subtask
      |> Subtask.changeset(Map.put(attrs, "workspace_id", subtask.workspace_id))
      |> Repo.update()

    with {:ok, updated} <- result do
      Realtime.broadcast_workspace(subtask.workspace_id, "task.updated", %{
        task_id: subtask.task_id
      })

      {:ok, updated}
    end
  end

  def create_comment(%Task{} = task, attrs, actor) do
    author_attrs =
      case actor do
        %Mokaid.Members.Member{id: id} -> %{"author_member_id" => id}
        %Mokaid.Agents.Agent{id: id} -> %{"author_agent_id" => id}
        _ -> %{}
      end

    result =
      %TaskComment{}
      |> TaskComment.changeset(
        attrs
        |> Map.merge(author_attrs)
        |> Map.merge(%{"workspace_id" => task.workspace_id, "task_id" => task.id})
      )
      |> Repo.insert()

    with {:ok, comment} <- result do
      Realtime.broadcast_workspace(task.workspace_id, "task.comment_added", %{
        task_id: task.id,
        comment_id: comment.id
      })

      # A human wrote to the agent while it isn't running: have it answer so
      # the thread is a real conversation (the run's own comments cover the
      # rest). Agent-authored comments never trigger replies (no loops).
      if match?(%Mokaid.Members.Member{}, actor) and task.assigned_agent_id != nil and
           active_runs_for_task(task.workspace_id, task.id) == [] do
        # Typing indicator in the thread right away, before the LLM round-trip.
        Realtime.broadcast_workspace(task.workspace_id, "task.agent_typing", %{
          task_id: task.id,
          agent_id: task.assigned_agent_id
        })

        %{workspace_id: task.workspace_id, task_id: task.id}
        |> Mokaid.AI.Workers.ConverseWorker.new()
        |> Oban.insert()
      end

      {:ok, Repo.preload(comment, author_member: :user, author_agent: [])}
    end
  end

  ## ---------- AI execution ----------

  def create_execution_run(%Task{} = task, input \\ %{}) do
    %TaskExecutionRun{}
    |> TaskExecutionRun.changeset(%{
      "workspace_id" => task.workspace_id,
      "task_id" => task.id,
      "agent_id" => task.assigned_agent_id,
      "status" => "queued",
      "input" => input
    })
    |> Repo.insert()
  end

  def get_run(run_id), do: Repo.get(TaskExecutionRun, run_id)

  @active_run_statuses ~w(queued running waiting_for_approval)

  @doc "Runs of a task that are queued or in flight (cancellable)."
  def active_runs_for_task(workspace_id, task_id) do
    Repo.all(
      from r in TaskExecutionRun,
        where:
          r.workspace_id == ^workspace_id and r.task_id == ^task_id and
            r.status in ^@active_run_statuses
    )
  end

  @doc "True when the agent already has a run sent to the worker (in flight)."
  def agent_has_dispatched_run?(agent_id) do
    Repo.exists?(
      from r in TaskExecutionRun,
        where:
          r.agent_id == ^agent_id and
            (r.status in ["running", "waiting_for_approval"] or
               (r.status == "queued" and not is_nil(r.dispatched_at)))
    )
  end

  @doc "Oldest run waiting in the agent's queue (created but never dispatched)."
  def next_queued_run(agent_id) do
    Repo.one(
      from r in TaskExecutionRun,
        where: r.agent_id == ^agent_id and r.status == "queued" and is_nil(r.dispatched_at),
        order_by: [asc: r.inserted_at],
        limit: 1
    )
  end

  def mark_run_dispatched(%TaskExecutionRun{} = run) do
    run
    |> Ecto.Changeset.change(dispatched_at: DateTime.utc_now())
    |> Repo.update()
  end

  def update_run_progress(%TaskExecutionRun{} = run, attrs) do
    result =
      run
      |> TaskExecutionRun.progress_changeset(attrs)
      |> Repo.update()

    with {:ok, updated} <- result do
      Realtime.broadcast_workspace(run.workspace_id, "task.progress_changed", %{
        task_id: run.task_id,
        run_id: run.id,
        status: updated.status
      })

      {:ok, updated}
    end
  end

  ## ---------- Approvals ----------

  def create_approval_request(%TaskExecutionRun{} = run, attrs) do
    result =
      %TaskApprovalRequest{}
      |> TaskApprovalRequest.changeset(
        Map.merge(attrs, %{
          "workspace_id" => run.workspace_id,
          "task_id" => run.task_id,
          "run_id" => run.id,
          "agent_id" => run.agent_id
        })
      )
      |> Repo.insert()

    with {:ok, request} <- result do
      Realtime.broadcast_workspace(run.workspace_id, "task.approval_required", %{
        task_id: run.task_id,
        approval_request_id: request.id
      })

      {:ok, request}
    end
  end

  def get_approval_request(workspace_id, id) do
    Repo.one(
      from r in TaskApprovalRequest,
        where: r.workspace_id == ^workspace_id and r.id == ^id
    )
  end

  def decide_approval(%TaskApprovalRequest{} = request, status, reviewer, decision \\ nil) do
    request
    |> TaskApprovalRequest.decision_changeset(%{
      "status" => status,
      "reviewed_by_member_id" => reviewer.id,
      "decision_payload" => decision
    })
    |> Repo.update()
  end

  ## ---------- Activity ----------

  def record_activity(task, actor, event_type, metadata \\ %{}) do
    {actor_type, actor_id, actor_name} =
      case actor do
        %Mokaid.Members.Member{id: id, user: %{full_name: name}} -> {"member", id, name}
        %Mokaid.Members.Member{id: id} -> {"member", id, nil}
        %Mokaid.Agents.Agent{id: id, display_name: name} -> {"agent", id, name}
        _ -> {"system", nil, nil}
      end

    %TaskActivityEvent{}
    |> TaskActivityEvent.changeset(%{
      "workspace_id" => task.workspace_id,
      "task_id" => task.id,
      "actor_type" => actor_type,
      "actor_id" => actor_id,
      "actor_name" => actor_name,
      "event_type" => event_type,
      "metadata" => metadata
    })
    |> Repo.insert()
  end

  def counts_by_status(workspace_id) do
    Repo.all(
      from t in Task,
        where: t.workspace_id == ^workspace_id,
        group_by: t.status,
        select: {t.status, count(t.id)}
    )
    |> Map.new()
  end

  def completed_today_count(workspace_id) do
    start_of_day = DateTime.utc_now() |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])

    Repo.aggregate(
      from(t in Task,
        where:
          t.workspace_id == ^workspace_id and t.status == "completed" and
            t.completed_at >= ^start_of_day
      ),
      :count
    )
  end
end
