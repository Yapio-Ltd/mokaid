defmodule Mokaid.AI.ManagedRuntime do
  @moduledoc "Durable, capped reservations and live authority for managed runs."
  import Ecto.Query
  alias Mokaid.{Agents, Repo}
  alias Mokaid.AI.{RuntimeParticipant, RuntimePolicy, RuntimeRun}
  alias Mokaid.Billing.{CreditTransaction, Credits, Subscription}
  alias Mokaid.Tasks.{Task, TaskExecutionRun}
  alias Mokaid.Workspaces.Workspace

  @active ~w(queued running waiting_for_approval waiting_for_user_input)
  @terminal ~w(completed failed canceled)
  @lease_seconds 300

  def reserved?(run_id), do: Repo.exists?(from r in RuntimeRun, where: r.run_id == ^run_id)

  @doc "Keeps lifecycle callbacks terminal, retaining partial outputs after Stop."
  def progress(run_id, attrs) do
    case Mokaid.Tasks.get_run(run_id) do
      nil ->
        {:error, :run_not_found}

      run ->
        transaction(run.workspace_id, run.id, fn _workspace, _run, task ->
          current =
            Repo.one!(from r in TaskExecutionRun, where: r.id == ^run.id, lock: "FOR UPDATE")

          cond do
            current.status == "completed" ->
              current

            current.status in ~w(failed canceled) ->
              # Stop may precede artifact import and its final manifest. Keep that
              # manifest, but a delayed running/pause callback has no authority.
              if attrs["status"] in ~w(failed canceled) do
                save_progress!(current, Map.take(attrs, ~w(output token_usage cost_cents)))
              else
                current
              end

            attrs["status"] == "completed" ->
              Repo.rollback(:completion_callback_required)

            attrs["status"] == "failed" ->
              save_progress!(current, Map.take(attrs, ~w(output token_usage cost_cents)))

              case Mokaid.AI.handle_failure(current.id, attrs["error"] || "Execution interrupted") do
                {:ok, updated} -> updated
                {:error, reason} -> Repo.rollback(reason)
              end

            attrs["status"] == "canceled" ->
              updated = save_progress!(current, attrs)
              release_lead!(current, task)

              if task.status in ~w(waiting in_progress),
                do:
                  Mokaid.Tasks.update_task(task, %{"status" => "to_do", "progress_percent" => 0})

              Mokaid.AI.dispatch_next(current.workspace_id, current.agent_id)
              updated

            true ->
              case Mokaid.AI.handle_progress(current.id, attrs) do
                {:ok, updated} ->
                  if updated.status == "waiting_for_user_input" do
                    # A pause keeps its paid budget but consumes no runtime slot.
                    release_slots!(updated, task)
                    release_lead!(updated, task)
                  end

                  updated

                {:error, reason} ->
                  Repo.rollback(reason)
              end
          end
        end)
    end
  end

  defp save_progress!(run, attrs) do
    case Mokaid.Tasks.update_run_progress(run, attrs) do
      {:ok, updated} -> updated
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp release_lead!(run, task) do
    case Repo.get(Mokaid.Agents.Agent, run.agent_id) do
      %{current_task_id: task_id} = agent when task_id == task.id ->
        Agents.change_status(agent, "idle",
          current_task_id: nil,
          reason: "runtime_paused_or_stopped"
        )

      _ ->
        :ok
    end
  end

  @doc "Final output, task comment and completion effects share one durable receipt."
  def complete(run_id, output, token_usage, cost_cents) do
    case Mokaid.Tasks.get_run(run_id) do
      nil ->
        {:error, :run_not_found}

      run ->
        result =
          transaction(run.workspace_id, run.id, fn _workspace, _run, task ->
            current =
              Repo.one!(from r in TaskExecutionRun, where: r.id == ^run.id, lock: "FOR UPDATE")

            runtime = Repo.get_by(RuntimeRun, run_id: run.id)
            if is_nil(runtime), do: Repo.rollback(:reservation_required)

            cond do
              runtime.finalized_at || current.status in ~w(failed canceled) ||
                  task.status == "canceled" ->
                {current, nil}

              true ->
                case Mokaid.AI.handle_completion(run.id, output, token_usage, cost_cents) do
                  {:ok, updated} ->
                    summary = output["summary"]

                    comment =
                      if is_binary(summary) and String.trim(summary) != "" do
                        # This is a trusted runtime result, not a user form: keep the complete
                        # answer, including content beyond the comment editor's length limit.
                        Repo.insert!(%Mokaid.Tasks.TaskComment{
                          workspace_id: run.workspace_id,
                          task_id: task.id,
                          author_agent_id: run.agent_id,
                          body: String.replace(summary, <<0>>, "")
                        })
                      end

                    Repo.update!(
                      Ecto.Changeset.change(runtime,
                        finalized_at: DateTime.utc_now(),
                        final_comment_id: comment && comment.id
                      )
                    )

                    {updated, comment && comment.id}

                  {:error, reason} ->
                    Repo.rollback(reason)
                end
            end
          end)

        case result do
          {:ok, {updated, comment_id}} ->
            if comment_id,
              do:
                Mokaid.Realtime.broadcast_workspace(run.workspace_id, "task.comment_added", %{
                  task_id: run.task_id,
                  comment_id: comment_id
                })

            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc "Explicit member-authorized credit extension; the resume command is durably queued with its debit."
  def extend_budget(workspace_id, task_id, member, attrs) do
    request_id = attrs["request_id"]
    credits = attrs["additional_credits"]

    with :ok <- Mokaid.Permissions.authorize(member, "agents.run_ai"),
         true <- member.workspace_id == workspace_id and member.status == "active",
         {:ok, _} <- Ecto.UUID.cast(request_id),
         true <- credits in [500, 2000] do
      result =
        transaction(workspace_id, attrs["run_id"], fn workspace, run, task ->
          if task.id != task_id, do: Repo.rollback(:not_found)
          key = "runtime:extend:" <> workspace_id <> ":" <> request_id
          existing = Repo.get_by(CreditTransaction, idempotency_key: key)

          if existing do
            if existing.workspace_id != workspace_id or existing.run_id != run.id or
                 existing.metadata["additional_credits"] != credits,
               do: Repo.rollback(:idempotency_conflict)

            Map.take(existing.metadata, ~w(run_id reserved_credits budget_revision status))
          else
            live_run!(workspace, run, task)
            eligible_agent!(workspace_id, run.agent_id, task.id)
            runtime = Repo.get_by(RuntimeRun, run_id: run.id)

            if is_nil(runtime) or runtime.status != "reserved" or
                 run.status != "waiting_for_user_input" or
                 get_in(run.output || %{}, ["runtime", "status"]) != "waiting_for_budget",
               do: Repo.rollback(:budget_not_waiting)

            sub = lock_subscription!(workspace_id)

            if sub.monthly_credits == -1 != runtime.metered_only,
              do: Repo.rollback(:billing_plan_changed)

            if not runtime.metered_only and Credits.spendable(sub) < credits,
              do: Repo.rollback(:insufficient_credits)

            included =
              if runtime.metered_only,
                do: 0,
                else: min(max(sub.included_credits_remaining || 0, 0), credits)

            balance = if runtime.metered_only, do: 0, else: credits - included
            sub = update_balance!(sub, -included, -balance)

            funding =
              funding_parts(runtime) ++
                [funding_entry(included, balance, sub.credits_period_start)]

            runtime =
              Repo.update!(
                Ecto.Changeset.change(runtime,
                  budget_cents: runtime.budget_cents + div(credits, 10),
                  budget_revision: runtime.budget_revision + 1,
                  reserved_credits: runtime.reserved_credits + credits,
                  included_reserved: runtime.included_reserved + included,
                  balance_reserved: runtime.balance_reserved + balance,
                  funding: funding
                )
              )

            response = %{
              "run_id" => run.id,
              "reserved_credits" => runtime.reserved_credits,
              "budget_revision" => runtime.budget_revision,
              "status" => "running"
            }

            ledger!(
              run,
              sub,
              "runtime_reserve",
              if(runtime.metered_only, do: 0, else: -credits),
              "Additional task credits reserved",
              key,
              Map.merge(response, %{
                "additional_credits" => credits,
                "authorized_by_member_id" => member.id
              })
            )

            # Conditional transitions make a concurrent Stop win without losing credits.
            {count, _} =
              Repo.update_all(
                from(r in TaskExecutionRun,
                  where: r.id == ^run.id and r.status == "waiting_for_user_input"
                ),
                set: [status: "running", updated_at: DateTime.utc_now()]
              )

            if count != 1, do: Repo.rollback(:budget_not_waiting)

            {count, _} =
              Repo.update_all(
                from(t in Task,
                  where: t.id == ^task.id and t.status not in ["canceled", "completed"]
                ),
                set: [status: "in_progress", updated_at: DateTime.utc_now()]
              )

            if count != 1, do: Repo.rollback(:run_stopped)

            case %{
                   run_id: run.id,
                   workspace_id: workspace_id,
                   request_id: request_id,
                   budget_revision: runtime.budget_revision
                 }
                 |> Mokaid.AI.Workers.RuntimeResumeWorker.new()
                 |> Oban.insert() do
              {:ok, _} -> response
              {:error, reason} -> Repo.rollback(reason)
            end
          end
        end)

      if match?({:ok, _}, result) do
        Credits.broadcast_balance(workspace_id)
        Mokaid.Realtime.broadcast_workspace(workspace_id, "task.updated", %{task_id: task_id})
      end

      result
    else
      false -> {:error, :invalid_extension}
      :error -> {:error, :invalid_extension}
      error -> error
    end
  end

  @doc "Continues a paid, non-budget pause using an authorized persisted human comment."
  def resume_input(workspace_id, run_id, comment, member) do
    with :ok <- Mokaid.Permissions.authorize(member, "agents.run_ai"),
         true <- member.workspace_id == workspace_id and member.status == "active" do
      transaction(workspace_id, run_id, fn workspace, _run, task ->
        run = Repo.one!(from r in TaskExecutionRun, where: r.id == ^run_id, lock: "FOR UPDATE")
        runtime = Repo.get_by(RuntimeRun, run_id: run.id)

        # Expected denials are values, not nested transaction rollbacks: the
        # caller can persist its explanatory reply and mark the comment handled.
        with :ok <- input_resume_eligibility(workspace, run, task, runtime, comment, member) do
          updated = save_progress!(run, %{"status" => "running"})

          case Mokaid.Tasks.update_task(task, %{"status" => "in_progress"}) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          case %{
                 run_id: run.id,
                 workspace_id: workspace_id,
                 request_id: comment.id,
                 budget_revision: runtime.budget_revision,
                 payload: %{runtime_user_input: true, instruction: comment.body}
               }
               |> Mokaid.AI.Workers.RuntimeResumeWorker.new()
               |> Oban.insert() do
            {:ok, _} -> {:ok, updated}
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      end)
      |> case do
        {:ok, result} -> result
        error -> error
      end
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  defp input_resume_eligibility(workspace, run, task, runtime, comment, member) do
    policy = RuntimePolicy.payload(workspace)
    agent = Agents.get_agent(workspace.id, run.agent_id)

    cond do
      not policy.enabled ->
        {:error, :runtime_disabled}

      not policy.data_policy_accepted ->
        {:error, :data_policy_required}

      task.status in ~w(completed canceled) ->
        {:error, :run_stopped}

      run.agent_id != task.assigned_agent_id ->
        {:error, :agent_reassigned}

      not Mokaid.AI.TaskFollowup.available_agent?(agent) ->
        {:error, :agent_unavailable}

      agent.current_task_id not in [nil, task.id] ->
        {:error, :agent_busy}

      comment.workspace_id != workspace.id or comment.task_id != task.id or
        comment.author_member_id != member.id or not is_nil(comment.author_agent_id) or
          not is_nil(comment.deleted_at) ->
        {:error, :forbidden}

      is_nil(runtime) or runtime.status != "reserved" or run.status != "waiting_for_user_input" ->
        {:error, :run_not_waiting}

      get_in(run.output || %{}, ["runtime", "status"]) == "waiting_for_budget" ->
        {:error, :extend_credits}

      Repo.exists?(
        from a in Mokaid.Tasks.TaskApprovalRequest,
          where: a.run_id == ^run.id and a.status == "pending"
      ) ->
        {:error, :approval_pending}

      true ->
        :ok
    end
  end

  @doc "Already-produced files may be imported after Stop; only a recorded participant may author them."
  def authorize_output(workspace_id, run_id, attrs) do
    transaction(workspace_id, run_id, fn workspace, run, _task ->
      agent_id = attrs["agent_id"] || run.agent_id

      if not is_nil(workspace.deleted_at) or not is_binary(agent_id) or
           not match?({:ok, _}, Ecto.UUID.cast(agent_id)),
         do: Repo.rollback(:not_found)

      if not Repo.exists?(
           from p in RuntimeParticipant,
             where:
               p.workspace_id == ^workspace_id and p.run_id == ^run.id and p.agent_id == ^agent_id
         ),
         do: Repo.rollback(:participant_required)

      %{allowed: true, agent_id: agent_id}
    end)
  end

  def file(workspace_id, run_id, file_id) do
    transaction(workspace_id, run_id, fn workspace, run, task ->
      live_run!(workspace, run, task)

      attached_ids =
        List.wrap(run.input["drive_item_ids"]) ++ List.wrap(task.metadata["drive_item_ids"])

      item =
        Repo.get_by(Mokaid.Drive.DriveItem,
          id: file_id,
          workspace_id: workspace_id,
          kind: "file",
          status: "active"
        )

      if is_nil(item) or (item.linked_task_id != task.id and item.id not in attached_ids) or
           (not item.is_ai_readable and item.id not in attached_ids),
         do: Repo.rollback(:file_not_authorized)

      case item.storage_key && Mokaid.Storage.download_url(item.storage_key) do
        {:ok, url} ->
          %{
            id: item.id,
            name: item.name,
            mime_type: item.mime_type,
            size_bytes: item.size_bytes,
            download_url: url
          }

        _ ->
          Repo.rollback(:file_unavailable)
      end
    end)
  end

  def authorize(workspace_id, run_id, attrs) do
    transaction(workspace_id, run_id, fn workspace, run, task ->
      policy = live_run!(workspace, run, task)
      agent_id = attrs["agent_id"] || run.agent_id
      agent = eligible_agent!(workspace_id, agent_id, task.id)
      lead = eligible_agent!(workspace_id, run.agent_id, task.id)
      runtime = Repo.get_by(RuntimeRun, run_id: run.id)

      if runtime && runtime.status != "reserved", do: Repo.rollback(:reservation_closed)

      if runtime || agent_id != run.agent_id do
        participant =
          Repo.one(
            from p in RuntimeParticipant,
              where: p.run_id == ^run.id and p.agent_id == ^agent_id and is_nil(p.released_at)
          )

        if is_nil(participant) or
             DateTime.compare(participant.lease_expires_at, DateTime.utc_now()) != :gt,
           do: Repo.rollback(:lease_expired)

        Repo.update!(Ecto.Changeset.change(participant, lease_expires_at: lease_deadline()))
      end

      autonomy = Agents.autonomy_payload(agent)
      lead_autonomy = Agents.autonomy_payload(lead)
      grants = current_grants(workspace_id, agent.id)

      lead_grants =
        if agent.id == lead.id, do: grants, else: current_grants(workspace_id, lead.id)

      grants = Enum.filter(grants, &(&1 in lead_grants))
      tool = attrs["tool_name"]

      if not is_nil(tool) and (not is_binary(tool) or byte_size(tool) > 250),
        do: Repo.rollback(:invalid_request)

      if is_binary(tool) and tool != "" do
        if is_nil(runtime), do: Repo.rollback(:reservation_required)

        if disabled?(agent, autonomy, tool) or disabled?(lead, lead_autonomy, tool),
          do: Repo.rollback(:tool_denied)

        case String.split(tool, ":", parts: 3) do
          ["mcp", key, _] -> if key not in grants, do: Repo.rollback(:tool_not_granted)
          ["mcp" | _] -> Repo.rollback(:tool_not_granted)
          _ -> :ok
        end
      end

      response =
        Map.merge(policy, %{
          allowed: true,
          runtime_policy: policy,
          autonomy: autonomy,
          lead_autonomy: lead_autonomy,
          agent: %{tool_preferences: agent.tool_preferences || %{}},
          lead_tool_preferences: lead.tool_preferences || %{},
          allowed_mcp_keys: grants,
          granted_mcp_keys: grants,
          lease_seconds: @lease_seconds
        })

      # Resolve credentials only for this already-authorized call. This worker
      # callback is private; descriptors must never enter provider/model context.
      case is_binary(tool) && String.split(tool, ":", parts: 3) do
        ["mcp", key, _] ->
          case Mokaid.MCP.authorized_servers_for_agent(workspace_id, agent.id, key) do
            [server] -> Map.put(response, :mcp_server, server)
            _ -> Repo.rollback(:tool_not_granted)
          end

        _ ->
          response
      end
    end)
  end

  def reserve(workspace_id, run_id, attrs) do
    result =
      transaction(workspace_id, run_id, fn workspace, run, task ->
        policy = live_run!(workspace, run, task)
        agent = eligible_agent!(workspace_id, run.agent_id, task.id)

        case Repo.get_by(RuntimeRun, run_id: run.id) do
          %RuntimeRun{} = existing ->
            # A retried delivery never buys another budget, including after settlement.
            if existing.status == "reserved" do
              if attrs["recovery"] == true,
                do: recover_root_lease!(run, task, agent, policy.max_active_sessions),
                else: live_root_lease!(run)
            end

            reservation_payload(existing, run.id)

          nil ->
            complexity = attrs["complexity"] || "standard"
            if complexity not in ["standard", "complex"], do: Repo.rollback(:invalid_complexity)

            budget =
              if complexity == "complex",
                do: policy.budget_cents_complex,
                else: policy.budget_cents_standard

            credits = Credits.cost_cents_to_credits(budget)
            sub = lock_subscription!(workspace_id)
            metered_only = sub.monthly_credits == -1

            if not metered_only and Credits.spendable(sub) < credits,
              do: Repo.rollback(:insufficient_credits)

            reserve_slot!(run, task, agent, run.id, policy.max_active_sessions)

            included =
              if metered_only,
                do: 0,
                else: min(max(sub.included_credits_remaining || 0, 0), credits)

            balance = if metered_only, do: 0, else: credits - included
            sub = update_balance!(sub, -included, -balance)

            runtime =
              Repo.insert!(%RuntimeRun{
                workspace_id: workspace_id,
                run_id: run.id,
                budget_cents: budget,
                reserved_credits: credits,
                included_reserved: included,
                balance_reserved: balance,
                funding: [funding_entry(included, balance, sub.credits_period_start)],
                credits_period_start: sub.credits_period_start,
                metered_only: metered_only
              })

            unless metered_only do
              ledger!(
                run,
                sub,
                "runtime_reserve",
                -credits,
                "Runtime credit reservation",
                "runtime:reserve:#{run.id}",
                %{"reserved_credits" => credits}
              )
            end

            reservation_payload(runtime, run.id)
        end
      end)

    if match?({:ok, _}, result), do: Credits.broadcast_balance(workspace_id)
    result
  end

  def reserve_participant(workspace_id, run_id, attrs) do
    transaction(workspace_id, run_id, fn workspace, run, task ->
      policy = live_run!(workspace, run, task)
      runtime = Repo.get_by(RuntimeRun, run_id: run.id)
      if is_nil(runtime) or runtime.status != "reserved", do: Repo.rollback(:reservation_required)
      live_root_lease!(run)
      participant_id = attrs["participant_id"]

      if not is_binary(participant_id) or byte_size(participant_id) not in 1..128,
        do: Repo.rollback(:invalid_participant)

      agent = eligible_agent!(workspace_id, attrs["agent_id"], task.id)

      if attrs["recovery"] == true do
        recover_slot!(run, task, agent, participant_id, policy.max_active_sessions)
      else
        reserve_slot!(run, task, agent, participant_id, policy.max_active_sessions)
      end

      %{reserved: true, participant_id: participant_id, lease_seconds: @lease_seconds}
    end)
  end

  def release_participant(workspace_id, run_id, attrs) do
    transaction(workspace_id, run_id, fn _workspace, run, task ->
      if not is_binary(attrs["participant_id"]) or
           byte_size(attrs["participant_id"]) not in 1..128,
         do: Repo.rollback(:invalid_participant)

      case Repo.get_by(RuntimeParticipant,
             run_id: run.id,
             participant_id: attrs["participant_id"]
           ) do
        nil -> :ok
        participant -> release_slot!(participant, task)
      end

      %{released: true}
    end)
  end

  def settle(workspace_id, run_id, attrs) do
    result =
      transaction(workspace_id, run_id, fn _workspace, run, task ->
        runtime = Repo.get_by(RuntimeRun, run_id: run.id)
        if is_nil(runtime), do: Repo.rollback(:reservation_required)
        release_slots!(run, task)

        if runtime.status == "settled" do
          reservation_payload(runtime, run.id)
        else
          cost = attrs["cost_cents"]
          quality = attrs["usage_status"] || "unknown"
          if quality not in ~w(actual estimated unknown), do: Repo.rollback(:invalid_usage)

          if not is_nil(cost) and (not is_integer(cost) or cost < 0 or cost > 2_147_483_647),
            do: Repo.rollback(:invalid_usage)

          if is_nil(cost) or quality == "unknown" do
            runtime =
              Repo.update!(
                Ecto.Changeset.change(runtime, status: "pending_usage", usage_status: "unknown")
              )

            reservation_payload(runtime, run.id)
          else
            charged =
              min(
                runtime.reserved_credits,
                Credits.cost_cents_to_credits(min(cost, runtime.budget_cents))
              )

            sub = lock_subscription!(workspace_id)
            unused = runtime.reserved_credits - charged
            # Each explicit extension can be funded by a different monthly grant.
            # Refund only still-current included credits, never revive expired grants.
            {refund_included, refund_balance} =
              refund_parts(runtime, charged, sub.credits_period_start)

            unless runtime.metered_only do
              sub = update_balance!(sub, refund_included, refund_balance)

              ledger!(
                run,
                sub,
                "runtime_settle",
                refund_included + refund_balance,
                "Runtime credit settlement",
                "runtime:settle:#{run.id}",
                %{
                  "charged_credits" => charged,
                  "usage_status" => quality,
                  "expired_unused_credits" => unused - refund_included - refund_balance
                }
              )
            end

            runtime =
              Repo.update!(
                Ecto.Changeset.change(runtime,
                  status: "settled",
                  reported_cost_cents: cost,
                  charged_credits: charged,
                  usage_status: quality,
                  settled_at: DateTime.utc_now()
                )
              )

            case Mokaid.Billing.record_usage(
                   workspace_id,
                   "agent",
                   run.agent_id,
                   "ai_cost",
                   1,
                   "run",
                   cost_cents: cost,
                   metadata: %{
                     "run_id" => run.id,
                     "task_id" => task.id,
                     "usage_status" => quality,
                     "charged_credits" => charged,
                     "runtime" => "managed"
                   }
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end

            reservation_payload(runtime, run.id)
          end
        end
      end)

    if match?({:ok, _}, result), do: Credits.broadcast_balance(workspace_id)
    result
  end

  @doc "Terminal callbacks release capacity, but never pretend unknown usage was free."
  def terminal(%TaskExecutionRun{status: status} = run) when status in @terminal do
    if reserved?(run.id),
      do: settle(run.workspace_id, run.id, %{"usage_status" => "unknown"}),
      else: :ok
  end

  def terminal(_run), do: :ok

  defp transaction(workspace_id, run_id, fun) do
    with {:ok, _} <- Ecto.UUID.cast(workspace_id), {:ok, _} <- Ecto.UUID.cast(run_id) do
      Repo.transaction(fn ->
        # One lock order for budget, slots, authorization and settlement.
        workspace =
          Repo.one(from w in Workspace, where: w.id == ^workspace_id, lock: "FOR UPDATE")

        if is_nil(workspace), do: Repo.rollback(:not_found)
        run = Repo.get_by(TaskExecutionRun, id: run_id, workspace_id: workspace_id)
        if is_nil(run), do: Repo.rollback(:not_found)
        task = Repo.get_by(Task, id: run.task_id, workspace_id: workspace_id)
        if is_nil(task), do: Repo.rollback(:not_found)
        fun.(workspace, run, task)
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp live_run!(workspace, run, task) do
    policy = RuntimePolicy.payload(workspace)
    if not policy.enabled, do: Repo.rollback(:runtime_disabled)
    if not policy.data_policy_accepted, do: Repo.rollback(:data_policy_required)

    if run.status not in @active or task.status in ~w(completed canceled),
      do: Repo.rollback(:run_stopped)

    if run.agent_id != task.assigned_agent_id, do: Repo.rollback(:agent_reassigned)
    policy
  end

  defp eligible_agent!(workspace_id, id, task_id) do
    agent =
      if is_binary(id) and match?({:ok, _}, Ecto.UUID.cast(id)),
        do: Repo.get_by(Mokaid.Agents.Agent, id: id, workspace_id: workspace_id)

    if is_nil(agent) or agent.kind not in ~w(ai hybrid) or not agent.ai_enabled or
         not is_nil(agent.archived_at) or agent.status in ~w(archived training offline),
       do: Repo.rollback(:agent_unavailable)

    if not is_nil(agent.current_task_id) and agent.current_task_id != task_id,
      do: Repo.rollback(:agent_busy)

    agent
  end

  defp reserve_slot!(run, task, agent, key, limit) do
    expire_slots!(run.workspace_id)

    case Repo.get_by(RuntimeParticipant, run_id: run.id, participant_id: key) do
      %RuntimeParticipant{agent_id: id, released_at: nil} = participant when id == agent.id ->
        Repo.update!(Ecto.Changeset.change(participant, lease_expires_at: lease_deadline()))

      %RuntimeParticipant{} ->
        Repo.rollback(:participant_released)

      nil ->
        count =
          Repo.aggregate(
            from(p in RuntimeParticipant,
              where: p.workspace_id == ^run.workspace_id and is_nil(p.released_at)
            ),
            :count
          )

        if count >= limit, do: Repo.rollback(:runtime_capacity)

        if Repo.exists?(
             from p in RuntimeParticipant,
               where:
                 p.workspace_id == ^run.workspace_id and p.agent_id == ^agent.id and
                   is_nil(p.released_at)
           ),
           do: Repo.rollback(:agent_busy)

        Repo.insert!(%RuntimeParticipant{
          workspace_id: run.workspace_id,
          run_id: run.id,
          agent_id: agent.id,
          participant_id: key,
          lease_expires_at: lease_deadline()
        })

        if agent.id != run.agent_id,
          do:
            Agents.change_status(agent, "busy",
              current_task_id: task.id,
              reason: "runtime_participant"
            )
    end
  end

  defp release_slots!(run, task) do
    Repo.all(from p in RuntimeParticipant, where: p.run_id == ^run.id and is_nil(p.released_at))
    |> Enum.each(&release_slot!(&1, task))
  end

  defp release_slot!(%RuntimeParticipant{released_at: nil} = participant, task) do
    Repo.update!(Ecto.Changeset.change(participant, released_at: DateTime.utc_now()))
    agent = Repo.get(Mokaid.Agents.Agent, participant.agent_id)

    if agent && agent.id != task.assigned_agent_id && agent.current_task_id == task.id &&
         agent.status == "busy",
       do:
         Agents.change_status(agent, "idle",
           current_task_id: nil,
           reason: "runtime_participant_released"
         )

    :ok
  end

  defp release_slot!(_, _), do: :ok

  defp current_grants(workspace_id, agent_id) do
    Repo.all(
      from g in Mokaid.MCP.AgentGrant,
        join: i in assoc(g, :installation),
        join: s in assoc(i, :server),
        where:
          g.workspace_id == ^workspace_id and i.workspace_id == ^workspace_id and
            g.agent_id == ^agent_id and g.granted and i.status == "connected" and s.enabled,
        select: s.key
    )
  end

  defp disabled?(agent, autonomy, tool) do
    Enum.any?(Map.get(agent.tool_preferences || %{}, "disabled", []), &matches?(&1, tool)) or
      Enum.any?(autonomy.rules, &(&1.behavior == "deny" and matches?(&1.tool_pattern, tool)))
  end

  defp live_root_lease!(run) do
    root = Repo.get_by(RuntimeParticipant, run_id: run.id, participant_id: run.id)

    if is_nil(root) or not is_nil(root.released_at) or
         DateTime.compare(root.lease_expires_at, DateTime.utc_now()) != :gt,
       do: Repo.rollback(:lease_expired)
  end

  # The authenticated worker may request recovery only after obtaining its own
  # durable execution claim. This reuses the paid reservation; it never buys one.
  defp recover_root_lease!(run, task, agent, limit) do
    recover_slot!(run, task, agent, run.id, limit)
  end

  defp recover_slot!(run, task, agent, key, limit) do
    expire_slots!(run.workspace_id)
    root = Repo.get_by(RuntimeParticipant, run_id: run.id, participant_id: key)
    if is_nil(root) or root.agent_id != agent.id, do: Repo.rollback(:participant_required)

    if root.released_at do
      count =
        Repo.aggregate(
          from(p in RuntimeParticipant,
            where: p.workspace_id == ^run.workspace_id and is_nil(p.released_at)
          ),
          :count
        )

      if count >= limit, do: Repo.rollback(:runtime_capacity)

      if Repo.exists?(
           from p in RuntimeParticipant,
             where:
               p.workspace_id == ^run.workspace_id and p.agent_id == ^agent.id and
                 is_nil(p.released_at)
         ),
         do: Repo.rollback(:agent_busy)
    end

    Repo.update!(
      Ecto.Changeset.change(root, released_at: nil, lease_expires_at: lease_deadline())
    )

    if agent.current_task_id != task.id,
      do:
        Agents.change_status(agent, "busy", current_task_id: task.id, reason: "runtime_recovered")
  end

  defp expire_slots!(workspace_id) do
    now = DateTime.utc_now()

    Repo.all(
      from p in RuntimeParticipant,
        where:
          p.workspace_id == ^workspace_id and is_nil(p.released_at) and p.lease_expires_at <= ^now
    )
    |> Enum.each(fn p ->
      old_run = Repo.get!(TaskExecutionRun, p.run_id)
      release_slot!(p, Repo.get!(Task, old_run.task_id))
    end)
  end

  defp matches?(pattern, tool) when is_binary(pattern) do
    expression = pattern |> Regex.escape() |> String.replace("\\*", ".*")
    Regex.match?(Regex.compile!("\\A" <> expression <> "\\z"), tool)
  end

  defp matches?(_, _), do: false
  defp lease_deadline, do: DateTime.add(DateTime.utc_now(), @lease_seconds, :second)

  defp lock_subscription!(workspace_id) do
    Repo.one(from s in Subscription, where: s.workspace_id == ^workspace_id, lock: "FOR UPDATE") ||
      Repo.rollback(:insufficient_credits)
  end

  defp funding_entry(included, balance, period) do
    %{
      "included" => included,
      "balance" => balance,
      "period" => period && DateTime.to_iso8601(period)
    }
  end

  defp funding_parts(%RuntimeRun{funding: [_ | _] = funding}), do: funding

  defp funding_parts(runtime),
    do: [
      funding_entry(
        runtime.included_reserved,
        runtime.balance_reserved,
        runtime.credits_period_start
      )
    ]

  defp refund_parts(runtime, charged, current_period) do
    current_period = current_period && DateTime.to_iso8601(current_period)

    {_, included, balance} =
      Enum.reduce(funding_parts(runtime), {charged, 0, 0}, fn part, {remaining, ri, rb} ->
        spent_included = min(remaining, part["included"])
        spent_balance = min(remaining - spent_included, part["balance"])

        refund_included =
          if part["period"] == current_period, do: part["included"] - spent_included, else: 0

        {remaining - spent_included - spent_balance, ri + refund_included,
         rb + part["balance"] - spent_balance}
      end)

    {included, balance}
  end

  defp update_balance!(sub, included, balance) do
    {1, [updated]} =
      Repo.update_all(from(s in Subscription, where: s.id == ^sub.id, select: s),
        inc: [included_credits_remaining: included, credits_balance: balance]
      )

    updated
  end

  defp ledger!(run, sub, kind, amount, description, key, metadata) do
    %CreditTransaction{}
    |> CreditTransaction.changeset(%{
      workspace_id: run.workspace_id,
      run_id: run.id,
      agent_id: run.agent_id,
      kind: kind,
      amount: amount,
      balance_after: Credits.spendable(sub),
      description: description,
      idempotency_key: key,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp reservation_payload(runtime, participant_id) do
    %{
      reserved: runtime.status == "reserved",
      status: runtime.status,
      budget_cents: runtime.budget_cents,
      budget_revision: runtime.budget_revision,
      reserved_credits: runtime.reserved_credits,
      charged_credits: runtime.charged_credits,
      usage_status: runtime.usage_status,
      participant_id: participant_id,
      lease_seconds: @lease_seconds
    }
  end
end
