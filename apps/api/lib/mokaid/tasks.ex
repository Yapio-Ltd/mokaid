defmodule Mokaid.Tasks do
  @moduledoc "Tasks, subtasks, comments, approvals and AI execution runs."

  import Ecto.Query

  alias Mokaid.Agents
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
        preload: ^@preloads
    )
  end

  def list_tasks(workspace_id, filters \\ %{}) do
    from(t in Task,
      where: t.workspace_id == ^workspace_id,
      preload: [:project, :assigned_agent, :subtasks],
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
      Realtime.broadcast_workspace(workspace_id, "task.created", %{task_id: task.id})
      {:ok, Repo.preload(task, @preloads)}
    end
  end

  def update_task(%Task{} = task, attrs, actor \\ nil) do
    old_status = task.status

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
            status: updated.status,
            progress_percent: updated.progress_percent,
            assigned_agent_id: updated.assigned_agent_id
          })

          if updated.status == "completed" do
            Realtime.broadcast_workspace(task.workspace_id, "task.completed", %{
              task_id: updated.id
            })

            maybe_celebrate_agent(updated)
          end

        true ->
          Realtime.broadcast_workspace(task.workspace_id, "task.updated", %{
            task_id: updated.id
          })
      end

      {:ok, Repo.preload(updated, @preloads, force: true)}
    end
  end

  defp maybe_celebrate_agent(%Task{assigned_agent_id: nil}), do: :ok

  defp maybe_celebrate_agent(%Task{} = task) do
    case Agents.get_agent(task.workspace_id, task.assigned_agent_id) do
      nil -> :ok
      agent -> Agents.change_status(agent, "idle", reason: "task_completed")
    end
  end

  def delete_task(%Task{} = task) do
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
