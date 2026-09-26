defmodule Mokaid.AI.TaskFollowup do
  @moduledoc "Authorizes and applies one idle task-thread routing decision exactly once."

  import Ecto.Query

  alias Mokaid.{AI, Agents, Audit, Members, Permissions, Repo, Tasks}
  alias Mokaid.Tasks.{Task, TaskComment}

  def available_agent?(%Agents.Agent{
        ai_enabled: true,
        kind: kind,
        status: status,
        archived_at: nil
      }),
      do: kind in ["ai", "hybrid"] and status not in ["archived", "training", "offline"]

  def available_agent?(_), do: false

  @doc "A paid managed pause may receive conversation without creating another run."
  def waiting_managed_run(workspace_id, task_id) do
    case Tasks.active_runs_for_task(workspace_id, task_id) do
      [%{status: "waiting_for_user_input"} = run] -> run
      _ -> nil
    end
  end

  @doc "Only the latest unhandled human comment may trigger an idle reply."
  def trigger(workspace_id, task_id, comment_id) do
    with {:ok, id} <- Ecto.UUID.cast(comment_id) do
      comment =
        Repo.one(
          from c in TaskComment,
            where:
              c.workspace_id == ^workspace_id and c.task_id == ^task_id and
                not is_nil(c.author_member_id) and is_nil(c.author_agent_id) and
                is_nil(c.deleted_at),
            order_by: [desc: c.inserted_at, desc: c.id],
            limit: 1
        )

      if comment && comment.id == id && is_nil(comment.ai_handled_at), do: comment
    else
      _ -> nil
    end
  end

  def apply(workspace_id, task_id, params) do
    with {:ok, workspace_id} <- Ecto.UUID.cast(workspace_id),
         {:ok, task_id} <- Ecto.UUID.cast(task_id),
         true <- params["kind"] in ["chat", "resume"] do
      Repo.transaction(fn ->
        # Managed callbacks acquire the workspace before task/run rows. Follow
        # the same order when a comment resumes an existing paid execution.
        workspace =
          Repo.one(
            from w in Mokaid.Workspaces.Workspace,
              where: w.id == ^workspace_id,
              lock: "FOR UPDATE"
          )

        if is_nil(workspace) or not is_nil(workspace.deleted_at), do: Repo.rollback(:not_found)

        task =
          Repo.one(
            from t in Task,
              where: t.workspace_id == ^workspace_id and t.id == ^task_id,
              lock: "FOR UPDATE"
          )

        if is_nil(task) or is_nil(task.assigned_agent_id) or
             task.assigned_agent_id != params["agent_id"],
           do: Repo.rollback(:not_found)

        case trigger(workspace_id, task_id, params["comment_id"]) do
          nil ->
            # Missing, stale, deleted, agent-authored and already handled
            # triggers are all harmless no-ops, including delayed retries.
            %{outcome: "ignored"}

          comment ->
            handle(task, comment, params)
        end
      end)
    else
      _ -> {:error, :invalid_followup}
    end
  end

  defp handle(task, comment, params) do
    member = Members.get_member(task.workspace_id, comment.author_member_id)

    if is_nil(member) or member.status != "active" or not Permissions.can?(member, "tasks.view"),
      do: Repo.rollback(:forbidden)

    waiting = waiting_managed_run(task.workspace_id, task.id)

    result =
      cond do
        superseded_by_stop?(task, comment) ->
          %{outcome: "ignored"}

        not available_agent?(Agents.get_agent(task.workspace_id, task.assigned_agent_id)) ->
          blocked(task, :agent_unavailable, params["language"])

        not is_nil(waiting) ->
          handle_waiting(task, waiting, comment, member, params)

        Tasks.active_runs_for_task(task.workspace_id, task.id) != [] ->
          %{outcome: "already_running"}

        params["kind"] == "chat" ->
          post_reply(task, params["reply"])
          %{outcome: "replied"}

        not Permissions.can?(member, "agents.run_ai") ->
          blocked(task, :forbidden, params["language"])

        true ->
          start_run(task, comment, member, params["language"])
      end

    comment
    |> Ecto.Changeset.change(ai_handled_at: DateTime.utc_now())
    |> Repo.update!()

    result
  end

  defp handle_waiting(task, run, comment, member, params) do
    cond do
      params["kind"] == "chat" ->
        post_reply(task, params["reply"])
        %{outcome: "replied"}

      not Permissions.can?(member, "agents.run_ai") ->
        blocked(task, :forbidden, params["language"])

      get_in(run.output || %{}, ["runtime", "status"]) == "waiting_for_budget" ->
        blocked(task, :extend_credits, params["language"])

      true ->
        case Mokaid.AI.ManagedRuntime.resume_input(task.workspace_id, run.id, comment, member) do
          {:ok, _} ->
            Audit.log(task.workspace_id, member, "ai.run_resumed", "task", task.id, %{
              run_id: run.id,
              comment_id: comment.id
            })

            %{outcome: "resumed", run_id: run.id}

          {:error, reason} ->
            blocked(task, reason, params["language"])
        end
    end
  end

  defp superseded_by_stop?(task, comment) do
    task.status in ["to_do", "canceled", "completed", "blocked"] and
      DateTime.compare(task.updated_at, comment.inserted_at) == :gt
  end

  defp start_run(task, comment, member, language) do
    input = AI.default_input(Tasks.get_task(task.workspace_id, task.id))

    input =
      Map.merge(input, %{
        "instruction" =>
          "#{input["instruction"]}\n\nLatest teammate instruction:\n#{comment.body}",
        "trigger_comment_id" => comment.id
      })

    case AI.start_run(task, input) do
      {:ok, run} ->
        current = Tasks.get_task(task.workspace_id, task.id)

        # Completed / blocked / in-review tasks also return to the live pipeline.
        if current.status != "in_progress" do
          case Tasks.update_task(current, %{
                 "status" => "in_progress",
                 "completed_at" => nil,
                 "progress_percent" => 0
               }) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        Audit.log(task.workspace_id, member, "ai.run_started", "task", task.id, %{
          run_id: run.id,
          comment_id: comment.id
        })

        %{outcome: "started", run_id: run.id}

      {:error, reason} ->
        blocked(task, reason, language)
    end
  end

  defp blocked(task, reason, language) do
    post_reply(task, failure_message(reason, language))

    %{
      outcome: "blocked",
      reason: if(is_atom(reason), do: to_string(reason), else: "start_failed")
    }
  end

  defp post_reply(task, body) when is_binary(body) do
    agent = Agents.get_agent(task.workspace_id, task.assigned_agent_id)

    case Tasks.create_comment(task, %{"body" => String.trim(body)}, agent) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp post_reply(_task, _body), do: Repo.rollback(:invalid_followup)

  defp failure_message(:forbidden, "fr"),
    do:
      "Votre rôle ne permet pas de lancer une exécution IA. Un responsable peut lancer cette tâche."

  defp failure_message(:forbidden, _),
    do: "Your role cannot start AI runs. A workspace manager can start this task."

  defp failure_message(:insufficient_credits, "fr"),
    do: "La tâche n’a pas pu démarrer : l’espace de travail n’a plus de crédits IA."

  defp failure_message(:insufficient_credits, _),
    do: "The task could not start because the workspace has no AI credits remaining."

  defp failure_message(:agent_unavailable, "fr"),
    do: "L’agent affecté à cette tâche n’est pas disponible pour une exécution IA."

  defp failure_message(:agent_unavailable, _),
    do: "The agent assigned to this task is not available for an AI run."

  defp failure_message(:extend_credits, "fr"),
    do:
      "Votre message est conservé. Le budget de cette tâche est épuisé : utilisez le bouton d’ajout de crédits dans la tâche pour autoriser la reprise. Votre message seul n’ajoute aucun crédit."

  defp failure_message(:extend_credits, _),
    do:
      "Your message has been saved. This task has reached its budget: use the add-credits button in the task to authorize continuation. A message does not add credits."

  defp failure_message(:approval_pending, "fr"),
    do:
      "Votre message est conservé. Une action attend encore votre décision : utilisez sa demande d’approbation avant de reprendre."

  defp failure_message(:approval_pending, _),
    do:
      "Your message has been saved. An action still needs your decision: use its approval request before continuing."

  defp failure_message(_reason, "fr"),
    do: "La tâche n’a pas pu redémarrer. Aucune nouvelle exécution n’a été lancée."

  defp failure_message(_reason, _),
    do: "The task could not restart. No new run was started."
end
