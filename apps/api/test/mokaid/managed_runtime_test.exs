defmodule Mokaid.ManagedRuntimeTest do
  use Mokaid.DataCase, async: true
  use Oban.Testing, repo: Mokaid.Repo
  alias Mokaid.{Agents, Tasks}
  alias Mokaid.AI.{ManagedRuntime, RuntimeParticipant, RuntimePolicy, RuntimeRun}
  alias Mokaid.Billing.{CreditTransaction, Credits, Subscription}

  setup do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)
    {:ok, agent} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Lead"})

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{"title" => "Research", "assigned_agent_id" => agent.id, "status" => "in_progress"},
        member
      )

    {:ok, run} = Tasks.create_execution_run(task, %{"instruction" => "Research"})

    sub =
      Repo.insert!(%Subscription{
        workspace_id: workspace.id,
        monthly_credits: 1000,
        included_credits_remaining: 1000,
        credits_balance: 1500
      })

    {:ok, _} =
      RuntimePolicy.update(workspace.id, member, %{
        "enabled" => true,
        "data_policy_accepted" => true
      })

    %{workspace: workspace, member: member, agent: agent, task: task, run: run, sub: sub}
  end

  test "reserves once and settles once, charging only capped consumed credits", c do
    assert {:ok, %{reserved_credits: 500}} = ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    assert Credits.summary(c.workspace.id).spendable == 2000

    assert {:ok, %{reserved_credits: 500}} =
             ManagedRuntime.reserve(c.workspace.id, c.run.id, %{"complexity" => "complex"})

    assert Credits.summary(c.workspace.id).spendable == 2000

    assert {:ok, %{charged_credits: 170, status: "settled"}} =
             ManagedRuntime.settle(c.workspace.id, c.run.id, %{
               "cost_cents" => 17,
               "usage_status" => "actual"
             })

    assert Credits.summary(c.workspace.id).spendable == 2330

    assert {:ok, %{charged_credits: 170}} =
             ManagedRuntime.settle(c.workspace.id, c.run.id, %{
               "cost_cents" => 150,
               "usage_status" => "estimated"
             })

    assert Credits.summary(c.workspace.id).spendable == 2330
    assert Repo.aggregate(from(t in CreditTransaction, where: t.run_id == ^c.run.id), :count) == 2
  end

  test "failure retains unknown reservation; late cost settles with cap without negative balance",
       c do
    assert {:ok, _} = ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    assert {:ok, _} = Tasks.update_run_progress(c.run, %{"status" => "failed"})
    assert Repo.get_by!(RuntimeRun, run_id: c.run.id).status == "pending_usage"
    assert Credits.summary(c.workspace.id).spendable == 2000

    assert Repo.aggregate(from(p in RuntimeParticipant, where: is_nil(p.released_at)), :count) ==
             0

    assert {:error, :run_stopped} = ManagedRuntime.authorize(c.workspace.id, c.run.id, %{})

    assert {:ok, %{charged_credits: 500}} =
             ManagedRuntime.settle(c.workspace.id, c.run.id, %{
               "cost_cents" => 900,
               "usage_status" => "estimated"
             })

    assert Credits.summary(c.workspace.id).spendable == 2000
  end

  test "cancellation accepts later reconciliation but forbids new tools", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    {:ok, _} = Tasks.update_run_progress(c.run, %{"status" => "canceled"})

    assert {:error, :run_stopped} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"tool_name" => "web_search"})

    assert {:ok, %{charged_credits: 0}} =
             ManagedRuntime.settle(c.workspace.id, c.run.id, %{
               "cost_cents" => 0,
               "usage_status" => "actual"
             })

    assert Credits.summary(c.workspace.id).spendable == 2500
  end

  test "unknown or invalid usage cannot silently refund work", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})

    assert {:error, :invalid_usage} =
             ManagedRuntime.settle(c.workspace.id, c.run.id, %{
               "cost_cents" => -1,
               "usage_status" => "actual"
             })

    assert {:ok, %{status: "pending_usage", charged_credits: nil}} =
             ManagedRuntime.settle(c.workspace.id, c.run.id, %{
               "cost_cents" => 0,
               "usage_status" => "unknown"
             })

    assert Credits.summary(c.workspace.id).spendable == 2000
  end

  test "insufficient funds rollback reservation and slot together", c do
    Repo.update!(Ecto.Changeset.change(c.sub, included_credits_remaining: 10, credits_balance: 0))
    assert {:error, :insufficient_credits} = ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    refute ManagedRuntime.reserved?(c.run.id)
    assert Repo.aggregate(RuntimeParticipant, :count) == 0
    assert Credits.summary(c.workspace.id).spendable == 10
  end

  test "unlimited plans meter without deducting or refunding balances", c do
    Repo.update!(Ecto.Changeset.change(c.sub, monthly_credits: -1))
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})

    assert {:ok, %{charged_credits: 100}} =
             ManagedRuntime.settle(c.workspace.id, c.run.id, %{
               "cost_cents" => 10,
               "usage_status" => "actual"
             })

    assert Credits.summary(c.workspace.id).spendable == 2500
  end

  test "refund does not revive expired monthly credit grant", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Subscription, c.sub.id),
        credits_period_start: DateTime.utc_now(),
        included_credits_remaining: 1000
      )
    )

    ManagedRuntime.settle(c.workspace.id, c.run.id, %{
      "cost_cents" => 10,
      "usage_status" => "actual"
    })

    assert Credits.summary(c.workspace.id).included_remaining == 1000
  end

  test "foreign workspace, changed assignment and disabled agent fail closed", c do
    {foreign, _} = workspace_fixture()
    assert {:error, :not_found} = ManagedRuntime.reserve(foreign.id, c.run.id, %{})
    Repo.update!(Ecto.Changeset.change(c.agent, ai_enabled: false))
    assert {:error, :agent_unavailable} = ManagedRuntime.authorize(c.workspace.id, c.run.id, %{})
    Repo.update!(Ecto.Changeset.change(c.agent, ai_enabled: true))
    Repo.update!(Ecto.Changeset.change(c.task, assigned_agent_id: nil))
    assert {:error, :agent_reassigned} = ManagedRuntime.authorize(c.workspace.id, c.run.id, %{})
  end

  test "live disabled tool and deny rules override earlier dispatch authority", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})

    assert {:ok, %{allowed: true}} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"tool_name" => "web_search"})

    {:ok, _} =
      Agents.upsert_permission_rule(c.workspace.id, c.agent.id, %{
        "tool_pattern" => "web_*",
        "behavior" => "deny"
      })

    assert {:error, :tool_denied} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"tool_name" => "web_search"})

    Repo.update!(
      Ecto.Changeset.change(c.agent, tool_preferences: %{"disabled" => ["upload_file"]})
    )

    assert {:error, :tool_denied} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"tool_name" => "upload_file"})

    assert {:error, :tool_not_granted} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{
               "tool_name" => "mcp:slack:post_message"
             })
  end

  test "capacity includes root and reserved colleagues, repeated participants are idempotent",
       c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})

    for n <- 1..3 do
      agent = colleague(c.workspace.id, n)

      assert {:ok, _} =
               ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, %{
                 "participant_id" => "child-#{n}",
                 "agent_id" => agent.id
               })

      assert {:ok, _} =
               ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, %{
                 "participant_id" => "child-#{n}",
                 "agent_id" => agent.id
               })
    end

    extra = colleague(c.workspace.id, 4)

    assert {:error, :runtime_capacity} =
             ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, %{
               "participant_id" => "child-4",
               "agent_id" => extra.id
             })

    assert {:ok, _} =
             ManagedRuntime.release_participant(c.workspace.id, c.run.id, %{
               "participant_id" => "child-1"
             })

    assert {:ok, _} =
             ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, %{
               "participant_id" => "child-4",
               "agent_id" => extra.id
             })
  end

  test "participant cannot bypass lead denial, and expired lease cannot renew", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    child = colleague(c.workspace.id, 1)

    assert {:error, :lease_expired} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"agent_id" => child.id})

    ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, %{
      "participant_id" => "child",
      "agent_id" => child.id
    })

    Agents.upsert_permission_rule(c.workspace.id, c.agent.id, %{
      "tool_pattern" => "web_search",
      "behavior" => "deny"
    })

    assert {:error, :tool_denied} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{
               "agent_id" => child.id,
               "tool_name" => "web_search"
             })

    participant = Repo.get_by!(RuntimeParticipant, run_id: c.run.id, agent_id: child.id)

    Repo.update!(
      Ecto.Changeset.change(participant, lease_expires_at: DateTime.add(DateTime.utc_now(), -1))
    )

    assert {:error, :lease_expired} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"agent_id" => child.id})
  end

  test "new work stays disabled without explicit US policy consent", c do
    {workspace, user} = workspace_fixture()
    refute RuntimePolicy.payload(workspace.id).enabled

    assert {:error, :data_policy_required} =
             RuntimePolicy.update(workspace.id, owner_member(workspace, user), %{
               "enabled" => true
             })

    {:ok, _} = RuntimePolicy.update(c.workspace.id, c.member, %{"data_policy_accepted" => false})
    assert {:error, :runtime_disabled} = ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
  end

  test "MCP grants are checked live and intersect both agents", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})

    server =
      Repo.insert!(%Mokaid.MCP.Server{
        key: "runtime-#{System.unique_integer([:positive])}",
        name: "Runtime MCP",
        category: "productivity",
        server_url: "https://mcp.example.test"
      })

    installation =
      Repo.insert!(%Mokaid.MCP.Installation{
        workspace_id: c.workspace.id,
        server_id: server.id,
        status: "connected"
      })

    grant =
      Repo.insert!(%Mokaid.MCP.AgentGrant{
        workspace_id: c.workspace.id,
        agent_id: c.agent.id,
        installation_id: installation.id,
        granted: true
      })

    tool = "mcp:#{server.key}:read"

    {:ok, installation} =
      Mokaid.MCP.store_credentials(installation, %{"api_key" => "initial-secret"})

    assert {:ok, auth} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"tool_name" => tool})

    assert auth.allowed_mcp_keys == [server.key]
    refute Map.has_key?(auth, :credentials)
    assert auth.mcp_server.key == server.key
    assert auth.mcp_server.credentials == %{"api_key" => "initial-secret"}
    {:ok, _} = Mokaid.MCP.store_credentials(installation, %{"api_key" => "rotated-secret"})

    assert {:ok, rotated} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"tool_name" => tool})

    assert rotated.mcp_server.credentials == %{"api_key" => "rotated-secret"}

    assert {:ok, ordinary} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"tool_name" => "web_search"})

    refute Map.has_key?(ordinary, :mcp_server)
    child = colleague(c.workspace.id, 1)

    ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, %{
      "participant_id" => "child",
      "agent_id" => child.id
    })

    assert {:error, :tool_not_granted} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{
               "agent_id" => child.id,
               "tool_name" => tool
             })

    Repo.update!(Ecto.Changeset.change(grant, granted: false))

    assert {:error, :tool_not_granted} =
             ManagedRuntime.authorize(c.workspace.id, c.run.id, %{"tool_name" => tool})
  end

  test "published artifact receipts survive cancellation and do not create duplicates", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    attrs = %{"run_id" => c.run.id, "agent_id" => c.agent.id, "artifact_key" => "artifact-one"}

    create = fn ->
      Repo.insert!(%Mokaid.Drive.DriveItem{
        workspace_id: c.workspace.id,
        linked_task_id: c.task.id,
        kind: "file",
        name: "result.txt",
        storage_key: "#{c.workspace.id}/runtime/result.txt",
        slug: "result",
        is_ai_readable: true,
        metadata: %{"runtime_artifact_key" => "artifact-one", "runtime_run_id" => c.run.id}
      })
    end

    assert {:ok, {:created, item}} =
             Mokaid.AI.RuntimeOutputs.publish(c.workspace.id, c.task.id, attrs, create)

    {:ok, _} = Tasks.update_run_progress(c.run, %{"status" => "canceled"})

    assert {:ok, {:existing, same}} =
             Mokaid.AI.RuntimeOutputs.publish(c.workspace.id, c.task.id, attrs, fn ->
               flunk("duplicate upload")
             end)

    assert same.id == item.id

    assert Repo.aggregate(
             from(d in Mokaid.Drive.DriveItem, where: d.linked_task_id == ^c.task.id),
             :count
           ) == 1
  end

  test "artifact reads cannot escape task scope or read an unreadable file", c do
    item =
      Repo.insert!(%Mokaid.Drive.DriveItem{
        workspace_id: c.workspace.id,
        kind: "file",
        name: "private.txt",
        storage_key: "#{c.workspace.id}/runtime/private.txt",
        slug: "private",
        is_ai_readable: true
      })

    assert {:error, :file_not_authorized} = ManagedRuntime.file(c.workspace.id, c.run.id, item.id)

    item =
      Repo.update!(Ecto.Changeset.change(item, linked_task_id: c.task.id, is_ai_readable: false))

    assert {:error, :file_not_authorized} = ManagedRuntime.file(c.workspace.id, c.run.id, item.id)
  end

  test "expired root lease cannot buy another session or reserve new colleagues", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    root = Repo.get_by!(RuntimeParticipant, run_id: c.run.id, participant_id: c.run.id)

    Repo.update!(
      Ecto.Changeset.change(root, lease_expires_at: DateTime.add(DateTime.utc_now(), -1))
    )

    assert {:error, :lease_expired} = ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    child = colleague(c.workspace.id, 1)

    assert {:error, :lease_expired} =
             ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, %{
               "participant_id" => "child",
               "agent_id" => child.id
             })

    assert Credits.summary(c.workspace.id).spendable == 2000

    assert {:ok, %{reserved: true}} =
             ManagedRuntime.reserve(c.workspace.id, c.run.id, %{"recovery" => true})

    assert {:ok, _} = ManagedRuntime.authorize(c.workspace.id, c.run.id, %{})
    assert Credits.summary(c.workspace.id).spendable == 2000
  end

  test "partial output import after cancellation preserves original participant scope", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    child = colleague(c.workspace.id, 1)

    ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, %{
      "participant_id" => "child",
      "agent_id" => child.id
    })

    {:ok, _} = Tasks.update_run_progress(c.run, %{"status" => "canceled"})

    assert {:ok, _} =
             ManagedRuntime.authorize_output(c.workspace.id, c.run.id, %{"agent_id" => child.id})

    stranger = colleague(c.workspace.id, 2)

    assert {:error, :participant_required} =
             ManagedRuntime.authorize_output(c.workspace.id, c.run.id, %{
               "agent_id" => stranger.id
             })

    {foreign, _} = workspace_fixture()

    assert {:error, :not_found} =
             ManagedRuntime.authorize_output(foreign.id, c.run.id, %{"agent_id" => child.id})
  end

  test "legacy completion callbacks cannot charge a managed reservation twice", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})

    ManagedRuntime.settle(c.workspace.id, c.run.id, %{
      "cost_cents" => 12,
      "usage_status" => "actual"
    })

    assert {:ok, _} =
             Mokaid.AI.handle_completion(c.run.id, %{"summary" => "Report delivered"}, %{}, 12)

    assert {:ok, _} =
             Mokaid.AI.handle_completion(c.run.id, %{"summary" => "Report delivered"}, %{}, 12)

    assert Credits.summary(c.workspace.id).spendable == 2380

    assert Repo.aggregate(
             from(e in Mokaid.Billing.UsageEvent,
               where: e.workspace_id == ^c.workspace.id and e.event_type == "ai_cost"
             ),
             :count
           ) == 1
  end

  test "explicit budget extension debits once and queues one durable resume command", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    pause_for_budget(c.run)

    params = %{
      "run_id" => c.run.id,
      "request_id" => Ecto.UUID.generate(),
      "additional_credits" => 500
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, first} =
               ManagedRuntime.extend_budget(c.workspace.id, c.task.id, c.member, params)

      assert first["budget_revision"] == 1
      assert first["reserved_credits"] == 1000
      assert Credits.summary(c.workspace.id).spendable == 1500

      assert {:ok, ^first} =
               ManagedRuntime.extend_budget(c.workspace.id, c.task.id, c.member, params)

      assert Credits.summary(c.workspace.id).spendable == 1500

      assert_enqueued worker: Mokaid.AI.Workers.RuntimeResumeWorker,
                      args: %{
                        run_id: c.run.id,
                        request_id: params["request_id"],
                        budget_revision: 1
                      }

      assert Repo.aggregate(
               from(j in Oban.Job, where: j.worker == "Mokaid.AI.Workers.RuntimeResumeWorker"),
               :count
             ) == 1

      assert Repo.get!(Mokaid.Tasks.TaskExecutionRun, c.run.id).status == "running"

      assert {:ok, %{budget_cents: 100, budget_revision: 1}} =
               ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    end)
  end

  test "resume outbox request identities cannot suppress another workspace's command", c do
    request_id = Ecto.UUID.generate()

    attrs = %{
      run_id: c.run.id,
      workspace_id: c.workspace.id,
      request_id: request_id,
      budget_revision: 0
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, first} = attrs |> Mokaid.AI.Workers.RuntimeResumeWorker.new() |> Oban.insert()
      {:ok, repeat} = attrs |> Mokaid.AI.Workers.RuntimeResumeWorker.new() |> Oban.insert()

      {:ok, other} =
        attrs
        |> Map.put(:workspace_id, Ecto.UUID.generate())
        |> Mokaid.AI.Workers.RuntimeResumeWorker.new()
        |> Oban.insert()

      assert repeat.id == first.id
      refute other.id == first.id
    end)
  end

  test "budget extension requires actual budget pause and rolls back on insufficient credits",
       c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})

    params = %{
      "run_id" => c.run.id,
      "request_id" => Ecto.UUID.generate(),
      "additional_credits" => 500
    }

    assert {:error, :budget_not_waiting} =
             ManagedRuntime.extend_budget(c.workspace.id, c.task.id, c.member, params)

    pause_for_budget(c.run)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Subscription, c.sub.id),
        included_credits_remaining: 0,
        credits_balance: 30
      )
    )

    assert {:error, :insufficient_credits} =
             ManagedRuntime.extend_budget(c.workspace.id, c.task.id, c.member, params)

    assert Repo.get_by!(RuntimeRun, run_id: c.run.id).reserved_credits == 500
    assert Repo.get!(Mokaid.Tasks.TaskExecutionRun, c.run.id).status == "waiting_for_user_input"
    assert Credits.summary(c.workspace.id).spendable == 30
  end

  test "budget extension rejects changed amount, foreign task, and unauthorized member", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    pause_for_budget(c.run)

    params = %{
      "run_id" => c.run.id,
      "request_id" => Ecto.UUID.generate(),
      "additional_credits" => 500
    }

    assert {:error, :not_found} =
             ManagedRuntime.extend_budget(c.workspace.id, Ecto.UUID.generate(), c.member, params)

    viewer = %{c.member | role: %Mokaid.Members.Role{name: "Viewer"}}

    assert {:error, :forbidden} =
             ManagedRuntime.extend_budget(c.workspace.id, c.task.id, viewer, params)

    assert {:ok, _} = ManagedRuntime.extend_budget(c.workspace.id, c.task.id, c.member, params)

    assert {:error, :idempotency_conflict} =
             ManagedRuntime.extend_budget(
               c.workspace.id,
               c.task.id,
               c.member,
               Map.put(params, "additional_credits", 2000)
             )

    assert Credits.summary(c.workspace.id).spendable == 1500
  end

  test "extension funding across monthly renewal refunds only the new unspent grant", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    pause_for_budget(c.run)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Subscription, c.sub.id),
        credits_period_start: DateTime.utc_now(),
        included_credits_remaining: 1000
      )
    )

    params = %{
      "run_id" => c.run.id,
      "request_id" => Ecto.UUID.generate(),
      "additional_credits" => 500
    }

    assert {:ok, _} = ManagedRuntime.extend_budget(c.workspace.id, c.task.id, c.member, params)

    assert {:ok, %{charged_credits: 600}} =
             ManagedRuntime.settle(c.workspace.id, c.run.id, %{
               "cost_cents" => 60,
               "usage_status" => "actual"
             })

    assert Credits.summary(c.workspace.id).included_remaining == 900
    assert Credits.summary(c.workspace.id).balance == 1500
  end

  test "managed finalization posts the complete answer once and awards completion only once", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})

    ManagedRuntime.settle(c.workspace.id, c.run.id, %{
      "cost_cents" => 8,
      "usage_status" => "actual"
    })

    summary = String.duplicate("Complete research evidence. ", 500) <> "LAST_SOURCE"
    output = %{"summary" => summary, "runtime" => %{"engine" => "openai_agents"}}
    assert {:ok, %{status: "completed"}} = ManagedRuntime.complete(c.run.id, output, %{}, 8)
    missions = Repo.get!(Mokaid.Agents.Agent, c.agent.id).missions_completed
    assert {:ok, %{status: "completed"}} = ManagedRuntime.complete(c.run.id, output, %{}, 8)
    assert Repo.get!(Mokaid.Agents.Agent, c.agent.id).missions_completed == missions
    comments = Repo.all(from x in Mokaid.Tasks.TaskComment, where: x.task_id == ^c.task.id)
    assert length(comments) == 1
    assert hd(comments).body == summary
    runtime = Repo.get_by!(RuntimeRun, run_id: c.run.id)
    assert runtime.finalized_at
    assert runtime.final_comment_id == hd(comments).id
    assert Credits.summary(c.workspace.id).spendable == 2420

    assert {:ok, %{status: "completed", output: ^output}} =
             ManagedRuntime.progress(c.run.id, %{"status" => "running", "output" => %{}})
  end

  test "late managed completion cannot undo cancellation or claim delivery", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    {:ok, _} = Tasks.update_run_progress(c.run, %{"status" => "canceled"})

    assert {:ok, %{status: "canceled"}} =
             ManagedRuntime.complete(c.run.id, %{"summary" => "Late result"}, %{}, 0)

    assert Repo.aggregate(
             from(x in Mokaid.Tasks.TaskComment, where: x.task_id == ^c.task.id),
             :count
           ) == 0

    assert Repo.get_by!(RuntimeRun, run_id: c.run.id).status == "pending_usage"
  end

  test "approval operation keys survive worker retry without re-pausing an approved run", c do
    attrs = %{
      "operation_key" => "operation-1",
      "tool_name" => "send_email",
      "input_payload" => %{"to" => "person@example.com"},
      "proposed_action" => "Send requested email"
    }

    assert {:ok, approval} = Mokaid.AI.handle_approval_request(c.run.id, attrs)
    assert {:ok, _} = Tasks.decide_approval(approval, "approved", c.member)
    {:ok, _} = Tasks.update_run_progress(Tasks.get_run(c.run.id), %{"status" => "running"})

    assert {:ok, %{id: id, status: "approved"}} =
             Mokaid.AI.handle_approval_request(c.run.id, attrs)

    assert id == approval.id
    assert Tasks.get_run(c.run.id).status == "running"

    assert Repo.aggregate(
             from(a in Mokaid.Tasks.TaskApprovalRequest, where: a.run_id == ^c.run.id),
             :count
           ) == 1

    assert {:error, :idempotency_conflict} =
             Mokaid.AI.handle_approval_request(
               c.run.id,
               Map.put(attrs, "tool_name", "make_purchase")
             )
  end

  test "managed failure retains partial artifacts and synchronizes task and agent once", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    Agents.change_status(c.agent, "busy", current_task_id: c.task.id, reason: "test")
    output = %{"summary" => "Partial research", "artifacts" => [%{"id" => Ecto.UUID.generate()}]}
    attrs = %{"status" => "failed", "output" => output, "error" => "One participant failed"}

    assert {:ok, %{status: "failed", output: ^output}} = ManagedRuntime.progress(c.run.id, attrs)
    assert Tasks.get_task(c.workspace.id, c.task.id).status == "to_do"
    assert Repo.get!(Mokaid.Agents.Agent, c.agent.id).status == "idle"
    assert Repo.get_by!(RuntimeRun, run_id: c.run.id).status == "pending_usage"
    count = Repo.aggregate(Mokaid.Notifications.Notification, :count)
    assert {:ok, %{status: "failed"}} = ManagedRuntime.progress(c.run.id, attrs)
    assert Repo.aggregate(Mokaid.Notifications.Notification, :count) == count

    assert {:ok, %{status: "failed"}} =
             ManagedRuntime.progress(c.run.id, %{"status" => "running"})
  end

  test "a late cancellation saves its partial manifest without reopening a stopped run", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    {:ok, _} = Tasks.update_run_progress(c.run, %{"status" => "canceled", "error" => "User stop"})
    output = %{"summary" => "Partial answer", "runtime" => %{"status" => "canceled"}}

    assert {:ok, %{status: "canceled", output: ^output, error: "User stop"}} =
             ManagedRuntime.progress(c.run.id, %{"status" => "canceled", "output" => output})

    assert {:ok, %{status: "canceled", output: ^output}} =
             ManagedRuntime.progress(c.run.id, %{"status" => "running", "output" => %{}})
  end

  test "managed budget pause releases slots but cannot buy another run through Run AI", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    child = colleague(c.workspace.id, 1)
    participant = %{"participant_id" => child.id, "agent_id" => child.id}
    ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, participant)

    assert {:ok, %{status: "waiting_for_user_input"}} =
             ManagedRuntime.progress(c.run.id, %{
               "status" => "waiting_for_user_input",
               "output" => %{"runtime" => %{"status" => "waiting_for_budget"}}
             })

    assert Repo.aggregate(from(p in RuntimeParticipant, where: is_nil(p.released_at)), :count) ==
             0

    assert Repo.get_by!(RuntimeRun, run_id: c.run.id).status == "reserved"
    assert {:ok, %{id: id}} = Mokaid.AI.start_run(c.task)
    assert id == c.run.id
    assert Mokaid.AI.cancel_active_runs_for_task(c.task)
    assert Tasks.get_run(c.run.id).status == "canceled"
    assert Repo.get_by!(RuntimeRun, run_id: c.run.id).status == "pending_usage"
  end

  test "recovered colleagues reuse the existing participant and budget", c do
    ManagedRuntime.reserve(c.workspace.id, c.run.id, %{})
    child = colleague(c.workspace.id, 1)
    participant = %{"participant_id" => child.id, "agent_id" => child.id}
    ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, participant)
    ManagedRuntime.release_participant(c.workspace.id, c.run.id, participant)

    assert {:error, :participant_released} =
             ManagedRuntime.reserve_participant(c.workspace.id, c.run.id, participant)

    assert {:ok, _} =
             ManagedRuntime.reserve_participant(
               c.workspace.id,
               c.run.id,
               Map.put(participant, "recovery", true)
             )

    assert Credits.summary(c.workspace.id).spendable == 2000

    assert Repo.aggregate(from(p in RuntimeParticipant, where: p.run_id == ^c.run.id), :count) ==
             2

    assert Repo.get!(Mokaid.Agents.Agent, child.id).current_task_id == c.task.id
  end

  defp pause_for_budget(run) do
    {:ok, _} =
      Tasks.update_run_progress(run, %{
        "status" => "waiting_for_user_input",
        "output" => %{"runtime" => %{"status" => "waiting_for_budget"}}
      })
  end

  defp colleague(workspace_id, n) do
    Repo.insert!(%Mokaid.Agents.Agent{
      workspace_id: workspace_id,
      kind: "ai",
      display_name: "Colleague #{n}",
      slug: "colleague-#{n}",
      status: "idle",
      ai_enabled: true
    })
  end
end
