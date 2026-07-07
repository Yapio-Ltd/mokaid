defmodule Mokaid.AI do
  @moduledoc """
  AI run orchestration: dispatches task execution to the Python worker
  (SQS in production, direct HTTP in dev) and processes worker callbacks.
  """

  alias Mokaid.Agents
  alias Mokaid.Agents.SkillLearning
  alias Mokaid.Billing
  alias Mokaid.Notifications
  alias Mokaid.Realtime
  alias Mokaid.Tasks
  alias Mokaid.Tasks.Task, as: WorkTask

  @doc """
  Creates an execution run for a task and enqueues it on the agent's serial
  queue. Each agent works one run at a time (missions resolve in order);
  different agents run in parallel. The run is dispatched to the AI worker
  immediately when the agent is free, otherwise when its current run ends.
  """
  def start_run(%WorkTask{} = task, input \\ %{}) do
    with :ok <- validate_ai_assignable(task),
         :ok <- validate_credits(task.workspace_id),
         {:ok, run} <- Tasks.create_execution_run(task, input) do
      # Visible in the pipeline right away, even while waiting in the queue.
      if task.status == "to_do" do
        Tasks.update_task(task, %{"status" => "in_progress"})
      end

      Billing.record_usage(
        task.workspace_id,
        "agent",
        task.assigned_agent_id,
        "ai_request",
        1,
        "request"
      )

      dispatch_next(run.workspace_id, run.agent_id)
      {:ok, run}
    end
  end

  defp validate_ai_assignable(%WorkTask{assigned_agent_id: nil}), do: {:error, :no_agent_assigned}
  defp validate_ai_assignable(_task), do: :ok

  # New AI work is blocked once the workspace is out of credits (unless
  # auto-recharge is armed or the plan is unlimited). A task already running
  # is never interrupted — the charge lands at completion and may dip the
  # balance negative, settled on the next top-up.
  defp validate_credits(workspace_id) do
    if Mokaid.Billing.Credits.can_start_task?(workspace_id),
      do: :ok,
      else: {:error, :insufficient_credits}
  end

  @doc """
  Sends the agent's next queued run to the worker — a no-op while a run is
  already in flight for that agent. Called whenever a run reaches a terminal
  state so the queue drains one mission at a time.
  """
  def dispatch_next(_workspace_id, nil), do: :ok

  def dispatch_next(workspace_id, agent_id) do
    if Tasks.agent_has_dispatched_run?(agent_id) do
      :ok
    else
      case Tasks.next_queued_run(agent_id) do
        nil ->
          :ok

        run ->
          {:ok, run} = Tasks.mark_run_dispatched(run)
          task = Tasks.get_task(workspace_id, run.task_id)
          agent = Agents.get_agent(workspace_id, agent_id)

          if agent do
            Agents.change_status(agent, "busy", current_task_id: run.task_id, reason: "ai_run")
          end

          if task && task.status in ["to_do", "waiting"] do
            Tasks.update_task(task, %{"status" => "in_progress"})
          end

          Realtime.broadcast_workspace(workspace_id, "task.run_started", %{
            task_id: run.task_id,
            run_id: run.id,
            title: task && task.title,
            agent_id: agent && agent.id,
            agent_name: agent && agent.display_name
          })

          %{run_id: run.id, workspace_id: workspace_id}
          |> Mokaid.AI.Workers.DispatchWorker.new()
          |> Oban.insert()

          :ok
      end
    end
  end

  @doc """
  Stops every queued/in-flight run of a task: the worker aborts the live
  run, the agent is released and its next queued mission starts. Returns
  true when something was actually canceled.
  """
  def cancel_active_runs_for_task(%WorkTask{} = task, reason \\ "Stopped by user") do
    runs = Tasks.active_runs_for_task(task.workspace_id, task.id)
    Enum.each(runs, &cancel_run(&1, reason))
    runs != []
  end

  @doc "Cancels a single run (worker abort + agent release + queue advance)."
  def cancel_run(run, reason) do
    # Only runs already sent to the worker have anything to abort remotely.
    if run.dispatched_at, do: worker_cancel(run.id)

    Tasks.update_run_progress(run, %{"status" => "canceled", "error" => reason})

    if run.agent_id do
      case Agents.get_agent(run.workspace_id, run.agent_id) do
        nil ->
          :ok

        agent ->
          if agent.status in ["busy", "waiting"] do
            Agents.change_status(agent, "idle", current_task_id: nil, reason: "run_canceled")
          end
      end
    end

    Realtime.broadcast_workspace(run.workspace_id, "task.progress_changed", %{
      task_id: run.task_id,
      run_id: run.id,
      status: "canceled",
      agent_id: run.agent_id
    })

    dispatch_next(run.workspace_id, run.agent_id)
    :ok
  end

  defp worker_cancel(run_id) do
    config = Application.fetch_env!(:mokaid, :ai_worker)

    case config[:dispatch] do
      :sqs ->
        config[:sqs_queue_url]
        |> ExAws.SQS.send_message(Jason.encode!(%{type: "cancel", run_id: run_id}))
        |> ExAws.request()

      _http ->
        Req.post(
          url: "#{config[:url]}/runs/#{run_id}/cancel",
          json: %{},
          headers: [{"authorization", "Bearer #{config[:token]}"}],
          retry: false
        )
    end

    :ok
  end

  @doc """
  Starts an AI run for the task unless one is already queued or in flight.
  Used when a task is dragged to "In Progress" or reassigned to an AI agent.
  """
  def ensure_started(%WorkTask{assigned_agent_id: nil}), do: :ok

  def ensure_started(%WorkTask{} = task) do
    agent = Agents.get_agent(task.workspace_id, task.assigned_agent_id)

    cond do
      agent == nil or agent.kind == "human_linked" or not agent.ai_enabled ->
        :ok

      Tasks.active_runs_for_task(task.workspace_id, task.id) != [] ->
        :ok

      true ->
        # Reload with comments/files so the run input carries the thread.
        task = Tasks.get_task(task.workspace_id, task.id) || task
        start_run(task, default_input(task))
        :ok
    end
  end

  @doc """
  Default run input: the original dispatch instruction, the dropped files
  and the task-thread conversation, so a (re)started mission has the full
  current context.
  """
  def default_input(%WorkTask{} = task) do
    %{
      "instruction" => task.metadata["instruction"] || task.description || task.title,
      "drive_item_ids" => task.metadata["drive_item_ids"] || [],
      "conversation" => conversation_entries(task)
    }
  end

  defp conversation_entries(%WorkTask{comments: %Ecto.Association.NotLoaded{}}), do: []

  defp conversation_entries(%WorkTask{comments: comments}) do
    comments
    |> Enum.sort_by(& &1.inserted_at, DateTime)
    |> Enum.take(-10)
    |> Enum.map(fn comment ->
      author =
        case {loaded(comment.author_agent), loaded(comment.author_member)} do
          {%{display_name: name}, _} -> "#{name} (agent)"
          {_, %{user: %{full_name: name}}} when is_binary(name) -> name
          _ -> "teammate"
        end

      %{"author" => author, "body" => comment.body}
    end)
  end

  defp loaded(%Ecto.Association.NotLoaded{}), do: nil
  defp loaded(other), do: other

  @doc "Handles a progress callback from the AI worker."
  def handle_progress(run_id, attrs) do
    with %{} = run <- Tasks.get_run(run_id),
         {:ok, updated_run} <- Tasks.update_run_progress(run, attrs) do
      # Sync task status when the worker signals it has actually started running.
      if attrs["status"] == "running" do
        task = Tasks.get_task(run.workspace_id, run.task_id)

        # "waiting" covers a run resumed after an approval decision.
        if task && task.status in ["to_do", "queued", "waiting"] do
          Tasks.update_task(task, %{"status" => "in_progress"})
        end

        # Bring the agent back to its desk too: a resumed run means it is
        # actively working again, not waiting on a decision.
        if run.agent_id do
          case Agents.get_agent(run.workspace_id, run.agent_id) do
            %{status: status} = agent when status != "busy" ->
              Agents.change_status(agent, "busy",
                current_task_id: run.task_id,
                reason: "run_running"
              )

            _ ->
              :ok
          end
        end
      end

      {:ok, updated_run}
    else
      nil -> {:error, :run_not_found}
    end
  end

  def handle_approval_request(run_id, attrs) do
    attrs = normalize_approval_attrs(attrs)

    # Create the approval request BEFORE flipping the run status: if the
    # insert fails the run keeps running instead of waiting on an approval
    # that doesn't exist (which would strand the task forever).
    with %{} = run <- Tasks.get_run(run_id),
         {:ok, request} <- Tasks.create_approval_request(run, attrs),
         {:ok, _run} <- Tasks.update_run_progress(run, %{"status" => "waiting_for_approval"}) do
      case Agents.get_agent(run.workspace_id, run.agent_id) do
        nil -> :ok
        agent -> Agents.change_status(agent, "waiting", reason: "approval_requested")
      end

      task = Tasks.get_task(run.workspace_id, run.task_id)

      if task do
        if task.status in ["to_do", "in_progress"] do
          Tasks.update_task(task, %{"status" => "waiting"})
        end

        Notifications.notify_member(
          run.workspace_id,
          task.created_by_member_id,
          "approval_requested",
          "Approval needed: #{task.title}",
          body: attrs["proposed_action"],
          resource_type: "task",
          resource_id: task.id
        )
      end

      Realtime.broadcast_workspace(run.workspace_id, "task.approval_required", %{
        task_id: run.task_id,
        run_id: run.id,
        approval_request_id: request.id,
        tool_name: request.tool_name,
        title: task && task.title,
        agent_id: run.agent_id
      })

      {:ok, request}
    else
      nil -> {:error, :run_not_found}
      error -> error
    end
  end

  # The Python worker posts `tool` / `risk` / `input`; the schema expects
  # `tool_name` / `risk_level` / `input_payload` (+ required `proposed_action`).
  # Accept both shapes so neither side can strand a run on a key mismatch.
  defp normalize_approval_attrs(attrs) do
    tool_name = attrs["tool_name"] || attrs["tool"] || "unknown_tool"
    risk = attrs["risk_level"] || attrs["risk"] || "high"
    input = attrs["input_payload"] || attrs["input"] || %{}

    proposed_action =
      attrs["proposed_action"] || attrs["summary"] ||
        default_proposed_action(tool_name, input)

    %{
      "tool_name" => tool_name,
      "risk_level" => if(risk in ~w(low medium high critical), do: risk, else: "high"),
      "input_payload" => if(is_map(input), do: input, else: %{"value" => input}),
      "proposed_action" => proposed_action
    }
  end

  defp default_proposed_action(tool_name, input) do
    detail =
      case input do
        %{"instruction" => instruction} when is_binary(instruction) -> ": #{instruction}"
        %{"subject" => subject} when is_binary(subject) -> ": #{subject}"
        _ -> ""
      end

    "The agent wants to run #{tool_name}#{detail}"
  end

  def handle_completion(run_id, output, token_usage \\ %{}, cost_cents \\ 0) do
    with %{} = run <- Tasks.get_run(run_id),
         {:ok, run} <-
           Tasks.update_run_progress(run, %{
             "status" => "completed",
             "output" => output,
             "token_usage" => token_usage,
             "cost_cents" => cost_cents
           }) do
      if cost_cents > 0 do
        # Meter real cost AND charge the workspace's AI credits (live balance).
        Billing.record_usage(run.workspace_id, "agent", run.agent_id, "ai_cost", 1, "run",
          cost_cents: cost_cents
        )

        Mokaid.Billing.Credits.charge_run(
          run.workspace_id,
          run.id,
          run.agent_id,
          cost_cents
        )
      end

      task = Tasks.get_task(run.workspace_id, run.task_id)

      if task do
        # Only transition to "in_review" when the run actually produced artifacts
        # (the output map carries an "artifacts" list from the Python worker).
        # Otherwise the agent completed but had nothing useful — keep it in_progress.
        artifacts = (output || %{})["artifacts"] || []
        has_output = length(List.wrap(artifacts)) > 0

        # The agent finished its assignment — hand the task to a human for
        # review, artifacts or not. Leaving it "in_progress" at 100% with an
        # idle agent reads as work still happening when nothing is.
        new_status =
          if task.status in ["completed", "canceled"], do: task.status, else: "in_review"

        Tasks.update_task(task, %{"status" => new_status, "progress_percent" => 100})

        # The run is over — release the agent so it can take new missions.
        if run.agent_id do
          case Agents.get_agent(run.workspace_id, run.agent_id) do
            nil ->
              :ok

            agent ->
              Agents.change_status(agent, "idle", current_task_id: nil, reason: "run_completed")
              # Skill learning — fire-and-forget (does not block the response).
              SkillLearning.record_mission(agent, task, output || %{})
          end
        end

        if has_output do
          Notifications.notify_member(
            run.workspace_id,
            task.created_by_member_id,
            "ai_run_completed",
            "Ready for review: #{task.title}",
            body:
              "The agent finished its work. Review the output and approve or request changes.",
            resource_type: "task",
            resource_id: task.id
          )
        end

        # Task launched from a chat thread → deliver the result there too, with
        # a natural message and the produced files attached.
        maybe_deliver_to_chat(run, task, output || %{})
      end

      Realtime.broadcast_workspace(run.workspace_id, "task.progress_changed", %{
        task_id: run.task_id,
        run_id: run.id,
        status: "completed",
        title: task && task.title,
        agent_id: run.agent_id
      })

      # This agent is free again — pull its next queued mission.
      dispatch_next(run.workspace_id, run.agent_id)

      {:ok, run}
    else
      nil -> {:error, :run_not_found}
      error -> error
    end
  end

  # Delivers a chat-launched task's result back into the agent's chat thread.
  # No-op for tasks that didn't originate from chat.
  defp maybe_deliver_to_chat(run, task, output) do
    chat_agent_id = get_in(task.metadata || %{}, ["chat_agent_id"])

    if is_binary(chat_agent_id) do
      outputs = chat_output_attachments(run.workspace_id, task.id)
      body = chat_delivery_message(task, outputs)
      Mokaid.AgentChat.deliver_task_output(run.workspace_id, chat_agent_id, body, outputs)
      # A summary line the worker may have produced, delivered as a follow-up.
      deliver_output_summary(run.workspace_id, chat_agent_id, output)
    end

    :ok
  rescue
    # Chat delivery is a nicety — never let it break run completion.
    error ->
      require Logger
      Logger.warning("chat_delivery_failed: #{inspect(error)}")
      :ok
  end

  defp chat_output_attachments(workspace_id, task_id) do
    import Ecto.Query

    Mokaid.Repo.all(
      from d in Mokaid.Drive.DriveItem,
        where:
          d.workspace_id == ^workspace_id and d.linked_task_id == ^task_id and
            d.kind == "file" and d.status == "active" and not is_nil(d.created_by_agent_id),
        order_by: [asc: d.inserted_at]
    )
    |> Enum.map(fn item ->
      %{
        "drive_item_id" => item.id,
        "name" => item.name,
        "mime_type" => item.mime_type,
        "size_bytes" => item.size_bytes
      }
    end)
  end

  # A warm, natural delivery line. French when the request looks French, else
  # English — matching the teammate's language keeps the chat coherent.
  defp chat_delivery_message(task, outputs) do
    instruction = get_in(task.metadata || %{}, ["instruction"]) || task.title || ""
    french? = looks_french?(instruction)

    cond do
      outputs == [] and french? ->
        "C'est fait ! J'ai terminé « #{task.title} ». Tu peux voir le détail dans la tâche."

      outputs == [] ->
        "Done! I finished “#{task.title}”. You can see the details in the task."

      french? ->
        "Voilà ce que tu m'as demandé pour « #{task.title} » — dis-moi si tu veux que j'ajuste quoi que ce soit !"

      true ->
        "Here's what you asked me for on “#{task.title}” — let me know if you'd like any changes!"
    end
  end

  defp deliver_output_summary(workspace_id, chat_agent_id, output) do
    summary = (output || %{})["summary"] || (output || %{})["headline"]

    if is_binary(summary) and String.trim(summary) != "" and String.length(summary) < 600 do
      Mokaid.AgentChat.post_agent_message(workspace_id, chat_agent_id, String.trim(summary))
    end

    :ok
  end

  defp looks_french?(text) when is_binary(text) do
    t = String.downcase(text)

    Regex.match?(
      ~r/\b(je|tu|nous|vous|le|la|les|des|une?|pour|avec|dans|qui|que|fais|fait|créer?|génère|voici|merci|s'il|à|é|è|ê|ç)\b/u,
      t
    )
  end

  defp looks_french?(_), do: false

  defp maybe_report_failure_to_chat(run, task) do
    chat_agent_id = get_in(task.metadata || %{}, ["chat_agent_id"])

    if is_binary(chat_agent_id) do
      instruction = get_in(task.metadata || %{}, ["instruction"]) || task.title || ""

      body =
        if looks_french?(instruction) do
          "Je suis désolé, j'ai rencontré un problème en travaillant sur « #{task.title} ». Peux-tu reformuler ou réessayer ? Je reste dispo."
        else
          "Sorry — I ran into a problem working on “#{task.title}”. Could you rephrase or try again? I'm still here to help."
        end

      Mokaid.AgentChat.post_agent_message(run.workspace_id, chat_agent_id, body)
    end

    :ok
  rescue
    error ->
      require Logger
      Logger.warning("chat_failure_report_failed: #{inspect(error)}")
      :ok
  end

  def handle_failure(run_id, error_message) do
    with %{} = run <- Tasks.get_run(run_id),
         {:ok, run} <-
           Tasks.update_run_progress(run, %{"status" => "failed", "error" => error_message}) do
      case Agents.get_agent(run.workspace_id, run.agent_id) do
        nil -> :ok
        agent -> Agents.change_status(agent, "blocked", reason: "run_failed")
      end

      task = Tasks.get_task(run.workspace_id, run.task_id)

      if task do
        # Keep the task in its current status — but store that the latest run failed.
        # The frontend reads latest_run.status == "failed" to show a red error banner.
        # A task parked in "waiting" (approval flow) goes back to to_do so it
        # doesn't look like it is still waiting on a decision.
        status_fix = if task.status == "waiting", do: %{"status" => "to_do"}, else: %{}
        Tasks.update_task(task, Map.merge(%{"progress_percent" => 0}, status_fix))

        Notifications.notify_member(
          run.workspace_id,
          task.created_by_member_id,
          "ai_run_failed",
          "Task failed: #{task.title}",
          body: error_message,
          resource_type: "task",
          resource_id: task.id
        )

        # Chat-launched task → tell the teammate in the thread, in character.
        maybe_report_failure_to_chat(run, task)
      end

      Realtime.broadcast_workspace(run.workspace_id, "task.progress_changed", %{
        task_id: run.task_id,
        run_id: run.id,
        status: "failed",
        error: error_message,
        title: task && task.title,
        agent_id: run.agent_id
      })

      # A failed mission must not block the rest of the agent's queue.
      dispatch_next(run.workspace_id, run.agent_id)

      {:ok, run}
    else
      nil -> {:error, :run_not_found}
      error -> error
    end
  end

  @doc """
  Resumes a paused run after a human decision on an approval request.

  The worker keeps paused-run state in memory, so if it restarted since the
  approval was requested it no longer knows the run. In that case the stale
  run is marked failed and — when the decision was an approval — a fresh run
  is dispatched automatically so the user's decision still takes effect.
  """
  def resume_after_approval(run_id, decision) do
    config = Application.fetch_env!(:mokaid, :ai_worker)
    body = %{run_id: run_id, decision: decision}

    result =
      case config[:dispatch] do
        :sqs ->
          config[:sqs_queue_url]
          |> ExAws.SQS.send_message(Jason.encode!(Map.put(body, :type, "resume")))
          |> ExAws.request()
          |> case do
            {:ok, _} -> :ok
            _ -> :error
          end

        _http ->
          case Req.post(
                 url: "#{config[:url]}/runs/#{run_id}/resume",
                 json: body,
                 headers: [{"authorization", "Bearer #{config[:token]}"}],
                 retry: false
               ) do
            {:ok, %{status: status}} when status in 200..299 -> :ok
            _ -> :error
          end
      end

    if result == :error, do: recover_lost_run(run_id, decision)
    :ok
  end

  defp recover_lost_run(run_id, decision) do
    with %{} = run <- Tasks.get_run(run_id) do
      task = Tasks.get_task(run.workspace_id, run.task_id)
      restart? = decision == "approved" and task != nil

      error_note =
        if restart?,
          do: "The AI worker was restarted; a new run was started automatically.",
          else: "The AI worker was restarted and this run could not be resumed."

      Tasks.update_run_progress(run, %{"status" => "failed", "error" => error_note})

      if restart? do
        start_run(task, run.input || %{})
      else
        if run.agent_id do
          case Agents.get_agent(run.workspace_id, run.agent_id) do
            nil -> :ok
            agent -> Agents.change_status(agent, "idle", reason: "run_lost")
          end
        end

        if task && task.status == "waiting" do
          Tasks.update_task(task, %{"status" => "to_do"})
        end

        dispatch_next(run.workspace_id, run.agent_id)
      end
    end

    :ok
  end
end
