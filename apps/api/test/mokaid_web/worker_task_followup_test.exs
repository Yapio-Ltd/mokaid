defmodule MokaidWeb.WorkerTaskFollowupTest do
  use MokaidWeb.ConnCase, async: false
  use Oban.Testing, repo: Mokaid.Repo
  import Ecto.Query

  alias Mokaid.{AI, Agents, Members, Tasks}
  alias Mokaid.Tasks.{TaskComment, TaskExecutionRun}

  setup %{conn: conn} do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)
    {:ok, agent} = Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Sira"})

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => "Check Google indexation",
          "assigned_agent_id" => agent.id,
          "status" => "waiting"
        },
        member
      )

    {:ok, comment} =
      Tasks.create_comment(task, %{"body" => "Fais la recherche sur mokaid.com"}, member)

    {:ok,
     conn: put_req_header(conn, "authorization", "Bearer test-token"),
     workspace: workspace,
     member: member,
     agent: agent,
     task: task,
     comment: comment}
  end

  test "work starts a real run only once, even after completion", ctx do
    result = callback(ctx, "resume") |> json_response(200)
    assert result["data"]["outcome"] == "started"
    run = Tasks.get_run(result["data"]["run_id"])
    assert run.input["trigger_comment_id"] == ctx.comment.id
    assert run.input["instruction"] =~ "Check Google indexation"
    assert run.input["instruction"] =~ ctx.comment.body
    assert Enum.any?(run.input["conversation"], &(&1["body"] == ctx.comment.body))
    assert Tasks.get_task(ctx.workspace.id, ctx.task.id).status == "in_progress"
    assert Repo.get!(TaskComment, ctx.comment.id).ai_handled_at
    {:ok, _} = Tasks.update_run_progress(run, %{"status" => "completed"})

    assert callback(ctx, "resume") |> json_response(200) |> get_in(["data", "outcome"]) ==
             "ignored"

    assert Repo.aggregate(from(r in TaskExecutionRun, where: r.task_id == ^ctx.task.id), :count) ==
             1
  end

  test "status chat never starts work or duplicates a reply", ctx do
    result = callback(ctx, "chat", %{"reply" => "La tâche est en attente."}) |> json_response(200)
    assert result["data"]["outcome"] == "replied"
    assert callback(ctx, "chat", %{"reply" => "La tâche est en attente."}) |> json_response(200)
    assert Tasks.active_runs_for_task(ctx.workspace.id, ctx.task.id) == []

    assert Repo.aggregate(
             from(c in TaskComment,
               where: c.task_id == ^ctx.task.id and c.author_agent_id == ^ctx.agent.id
             ),
             :count
           ) == 1
  end

  test "tasks.view does not grant run authority and callback cannot forge member", ctx do
    viewer = user_fixture()
    role = Repo.get_by!(Members.Role, name: "Viewer")

    member =
      %Members.Member{}
      |> Members.Member.changeset(%{
        "workspace_id" => ctx.workspace.id,
        "user_id" => viewer.id,
        "role_id" => role.id
      })
      |> Repo.insert!()

    {:ok, comment} = Tasks.create_comment(ctx.task, %{"body" => "Lance la tâche"}, member)
    ctx = %{ctx | comment: comment}
    result = callback(ctx, "resume", %{"member_id" => ctx.member.id}) |> json_response(200)
    assert result["data"] == %{"outcome" => "blocked", "reason" => "forbidden"}
    assert Tasks.active_runs_for_task(ctx.workspace.id, ctx.task.id) == []

    assert Enum.any?(
             Tasks.get_task(ctx.workspace.id, ctx.task.id).comments,
             &(&1.author_agent_id == ctx.agent.id and String.contains?(&1.body, "rôle"))
           )
  end

  test "insufficient credits explain failure without claiming a start", ctx do
    %Mokaid.Billing.Subscription{}
    |> Mokaid.Billing.Subscription.changeset(%{
      "workspace_id" => ctx.workspace.id,
      "credits_balance" => 0,
      "monthly_credits" => 100,
      "included_credits_remaining" => 0
    })
    |> Repo.insert!()

    result = callback(ctx, "resume") |> json_response(200)
    assert result["data"] == %{"outcome" => "blocked", "reason" => "insufficient_credits"}
    assert Tasks.active_runs_for_task(ctx.workspace.id, ctx.task.id) == []
    assert Tasks.get_task(ctx.workspace.id, ctx.task.id).status == "waiting"
  end

  test "stale, agent-authored and foreign comments cannot launch work", ctx do
    {:ok, latest} = Tasks.create_comment(ctx.task, %{"body" => "Attends"}, ctx.member)

    assert callback(ctx, "resume") |> json_response(200) |> get_in(["data", "outcome"]) ==
             "ignored"

    {:ok, agent_comment} = Tasks.create_comment(ctx.task, %{"body" => "Je suis prêt"}, ctx.agent)

    assert callback(%{ctx | comment: agent_comment}, "resume")
           |> json_response(200)
           |> get_in(["data", "outcome"]) == "ignored"

    {foreign_workspace, foreign_owner} = workspace_fixture()
    foreign_member = owner_member(foreign_workspace, foreign_owner)

    {:ok, foreign_task} =
      Tasks.create_task(foreign_workspace.id, %{"title" => "Other"}, foreign_member)

    {:ok, foreign_comment} =
      Tasks.create_comment(foreign_task, %{"body" => "Run"}, foreign_member)

    assert callback(%{ctx | comment: foreign_comment}, "resume")
           |> json_response(200)
           |> get_in(["data", "outcome"]) == "ignored"

    assert Tasks.active_runs_for_task(ctx.workspace.id, ctx.task.id) == []
    refute Repo.get!(TaskComment, latest.id).ai_handled_at
  end

  test "a current execution cannot be duplicated by a late decision", ctx do
    {:ok, _run} = AI.start_run(ctx.task, AI.default_input(ctx.task))

    assert callback(ctx, "resume") |> json_response(200) |> get_in(["data", "outcome"]) ==
             "already_running"

    assert length(Tasks.active_runs_for_task(ctx.workspace.id, ctx.task.id)) == 1
  end

  test "repeated starts return the existing run and stale task data cannot bypass the guard",
       ctx do
    {:ok, first} = AI.start_run(ctx.task, AI.default_input(ctx.task))
    {:ok, duplicate} = AI.start_run(ctx.task, %{"instruction" => "Duplicate button click"})
    assert first.id == duplicate.id

    assert Repo.aggregate(from(r in TaskExecutionRun, where: r.task_id == ^ctx.task.id), :count) ==
             1
  end

  test "a stop while classification is pending wins; a later new request can restart", ctx do
    {:ok, stopped} = Tasks.update_task(ctx.task, %{"status" => "canceled"})

    assert callback(ctx, "resume") |> json_response(200) |> get_in(["data", "outcome"]) ==
             "ignored"

    assert Tasks.active_runs_for_task(ctx.workspace.id, ctx.task.id) == []
    {:ok, later} = Tasks.create_comment(stopped, %{"body" => "Reprends maintenant"}, ctx.member)

    assert callback(%{ctx | comment: later}, "resume")
           |> json_response(200)
           |> get_in(["data", "outcome"]) == "started"
  end

  test "disabled, human-only and archived agents cannot be automatically started", ctx do
    for changes <- [
          [ai_enabled: false],
          [kind: "human_linked", linked_user_id: ctx.member.user_id],
          [status: "archived"],
          [status: "training"],
          [status: "offline"],
          [archived_at: DateTime.utc_now()]
        ] do
      ctx.agent
      |> Ecto.Changeset.change(changes)
      |> Repo.update!()

      {:ok, comment} = Tasks.create_comment(ctx.task, %{"body" => "Continue"}, ctx.member)
      result = callback(%{ctx | comment: comment}, "resume") |> json_response(200)
      assert result["data"] == %{"outcome" => "blocked", "reason" => "agent_unavailable"}
      assert Tasks.active_runs_for_task(ctx.workspace.id, ctx.task.id) == []

      Repo.get!(Agents.Agent, ctx.agent.id)
      |> Ecto.Changeset.change(
        ai_enabled: true,
        kind: "ai",
        status: "idle",
        archived_at: nil,
        linked_user_id: nil
      )
      |> Repo.update!()
    end
  end

  test "removed members, wrong agent and workspace are rejected", ctx do
    assert callback(ctx, "resume", %{"agent_id" => Ecto.UUID.generate()}) |> json_response(404)

    assert callback(ctx, "resume", %{"workspace_id" => Ecto.UUID.generate()})
           |> json_response(404)

    ctx.member |> Ecto.Changeset.change(status: "removed") |> Repo.update!()
    assert callback(ctx, "resume") |> json_response(403)
    assert Tasks.active_runs_for_task(ctx.workspace.id, ctx.task.id) == []
  end

  test "human jobs are anchored and agent replies cannot enqueue", ctx do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, comment} = Tasks.create_comment(ctx.task, %{"body" => "Continue"}, ctx.member)

      assert_enqueued worker: AI.Workers.ConverseWorker,
                      args: %{
                        workspace_id: ctx.workspace.id,
                        task_id: ctx.task.id,
                        comment_id: comment.id
                      }

      {:ok, agent_comment} = Tasks.create_comment(ctx.task, %{"body" => "Working"}, ctx.agent)
      refute_enqueued worker: AI.Workers.ConverseWorker, args: %{comment_id: agent_comment.id}
    end)
  end

  test "an actionable comment resumes the same managed pause once without buying credits", ctx do
    run = managed_pause(ctx, "waiting_for_user_input")
    balance = Mokaid.Billing.Credits.summary(ctx.workspace.id).spendable
    assert AI.TaskFollowup.waiting_managed_run(ctx.workspace.id, ctx.task.id).id == run.id

    Oban.Testing.with_testing_mode(:manual, fn ->
      result = callback(ctx, "resume") |> json_response(200)
      assert result["data"] == %{"outcome" => "resumed", "run_id" => run.id}
      assert Tasks.get_run(run.id).status == "running"
      assert Tasks.get_task(ctx.workspace.id, ctx.task.id).status == "in_progress"

      assert_enqueued worker: AI.Workers.RuntimeResumeWorker,
                      args: %{
                        run_id: run.id,
                        request_id: ctx.comment.id,
                        budget_revision: 0,
                        payload: %{runtime_user_input: true, instruction: ctx.comment.body}
                      }

      assert callback(ctx, "resume") |> json_response(200) |> get_in(["data", "outcome"]) ==
               "ignored"

      assert Repo.aggregate(
               from(j in Oban.Job, where: j.worker == "Mokaid.AI.Workers.RuntimeResumeWorker"),
               :count
             ) == 1
    end)

    assert Repo.aggregate(from(r in TaskExecutionRun, where: r.task_id == ^ctx.task.id), :count) ==
             1

    assert Mokaid.Billing.Credits.summary(ctx.workspace.id).spendable == balance
  end

  test "a human reply during a paid pause still enqueues classification", ctx do
    managed_pause(ctx, "waiting_for_user_input")

    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, comment} =
        Tasks.create_comment(
          ctx.task,
          %{"body" => "Voici les informations demandées"},
          ctx.member
        )

      assert_enqueued worker: AI.Workers.ConverseWorker,
                      args: %{
                        workspace_id: ctx.workspace.id,
                        task_id: ctx.task.id,
                        comment_id: comment.id
                      }

      {:ok, reply} = Tasks.create_comment(ctx.task, %{"body" => "Merci"}, ctx.agent)
      refute_enqueued worker: AI.Workers.ConverseWorker, args: %{comment_id: reply.id}
    end)
  end

  test "a budget-paused comment explains explicit extension without resuming or charging", ctx do
    run = managed_pause(ctx, "waiting_for_budget")
    balance = Mokaid.Billing.Credits.summary(ctx.workspace.id).spendable

    Oban.Testing.with_testing_mode(:manual, fn ->
      result = callback(ctx, "resume") |> json_response(200)
      assert result["data"] == %{"outcome" => "blocked", "reason" => "extend_credits"}
      refute_enqueued worker: AI.Workers.RuntimeResumeWorker
    end)

    assert Tasks.get_run(run.id).status == "waiting_for_user_input"
    assert Mokaid.Billing.Credits.summary(ctx.workspace.id).spendable == balance

    assert Enum.any?(
             Tasks.get_task(ctx.workspace.id, ctx.task.id).comments,
             &(&1.author_agent_id == ctx.agent.id and &1.body =~ "bouton d’ajout de crédits")
           )

    assert Repo.get!(TaskComment, ctx.comment.id).ai_handled_at
  end

  test "a status question during a managed pause remains a conversation", ctx do
    run = managed_pause(ctx, "waiting_for_user_input")

    Oban.Testing.with_testing_mode(:manual, fn ->
      result =
        callback(ctx, "chat", %{"reply" => "J’attends le fichier demandé."}) |> json_response(200)

      assert result["data"]["outcome"] == "replied"
      refute_enqueued worker: AI.Workers.RuntimeResumeWorker
    end)

    assert Tasks.get_run(run.id).status == "waiting_for_user_input"
  end

  test "managed resume cannot grant a pending sensitive approval or ignore revoked consent",
       ctx do
    run = managed_pause(ctx, "waiting_for_user_input")

    {:ok, approval} =
      Tasks.create_approval_request(run, %{
        "tool_name" => "send_email",
        "proposed_action" => "Send email",
        "input_payload" => %{}
      })

    result = callback(ctx, "resume") |> json_response(200)
    assert result["data"] == %{"outcome" => "blocked", "reason" => "approval_pending"}
    assert Repo.get!(Mokaid.Tasks.TaskApprovalRequest, approval.id).status == "pending"
    assert Tasks.get_run(run.id).status == "waiting_for_user_input"

    Tasks.decide_approval(approval, "denied", ctx.member)

    Mokaid.AI.RuntimePolicy.update(ctx.workspace.id, ctx.member, %{
      "data_policy_accepted" => false
    })

    {:ok, comment} = Tasks.create_comment(ctx.task, %{"body" => "Continue"}, ctx.member)
    result = callback(%{ctx | comment: comment}, "resume") |> json_response(200)
    assert result["data"] == %{"outcome" => "blocked", "reason" => "runtime_disabled"}
    assert Tasks.get_run(run.id).status == "waiting_for_user_input"
    assert Repo.get!(TaskComment, comment.id).ai_handled_at
  end

  test "workspace viewers cannot resume a paid managed run", ctx do
    run = managed_pause(ctx, "waiting_for_user_input")
    user = user_fixture()
    role = Repo.get_by!(Members.Role, name: "Viewer")

    member =
      %Members.Member{}
      |> Members.Member.changeset(%{
        "workspace_id" => ctx.workspace.id,
        "user_id" => user.id,
        "role_id" => role.id
      })
      |> Repo.insert!()

    {:ok, comment} = Tasks.create_comment(ctx.task, %{"body" => "Continue"}, member)

    result =
      callback(%{ctx | comment: comment}, "resume", %{"member_id" => ctx.member.id})
      |> json_response(200)

    assert result["data"] == %{"outcome" => "blocked", "reason" => "forbidden"}
    assert Tasks.get_run(run.id).status == "waiting_for_user_input"
  end

  defp managed_pause(ctx, reason) do
    Repo.insert!(%Mokaid.Billing.Subscription{
      workspace_id: ctx.workspace.id,
      monthly_credits: 1000,
      included_credits_remaining: 1000
    })

    {:ok, _} =
      Mokaid.AI.RuntimePolicy.update(ctx.workspace.id, ctx.member, %{
        "enabled" => true,
        "data_policy_accepted" => true
      })

    {:ok, run} = Tasks.create_execution_run(ctx.task, %{"instruction" => "Research"})
    {:ok, _} = Mokaid.AI.ManagedRuntime.reserve(ctx.workspace.id, run.id, %{})

    {:ok, run} =
      Mokaid.AI.ManagedRuntime.progress(run.id, %{
        "status" => "waiting_for_user_input",
        "output" => %{"runtime" => %{"status" => reason}}
      })

    run
  end

  defp callback(ctx, kind, extra \\ %{}) do
    post(
      ctx.conn,
      "/api/worker/tasks/#{ctx.task.id}/followup",
      Map.merge(
        %{
          "workspace_id" => ctx.workspace.id,
          "agent_id" => ctx.agent.id,
          "comment_id" => ctx.comment.id,
          "kind" => kind,
          "language" => "fr"
        },
        extra
      )
    )
  end
end
