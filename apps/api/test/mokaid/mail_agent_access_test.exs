defmodule Mokaid.Mail.AgentAccessTest do
  use Mokaid.DataCase, async: true
  alias Mokaid.{Repo, Tasks}
  alias Mokaid.Mail.{Account, AgentAccess}

  setup do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)

    agent =
      Repo.insert!(%Mokaid.Agents.Agent{
        workspace_id: workspace.id,
        kind: "ai",
        display_name: "Mail reader",
        slug: "mail-reader",
        ai_enabled: true,
        status: "idle"
      })

    account =
      Repo.insert!(%Account{
        workspace_id: workspace.id,
        member_id: member.id,
        provider: "imap",
        email_address: "mail@example.com",
        status: "active",
        settings: %{"private" => "must-never-reach-a-model"}
      })

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{"title" => "Read invoices", "assigned_agent_id" => agent.id, "status" => "in_progress"},
        member
      )

    {:ok, run} = Tasks.create_execution_run(task, %{"instruction" => "Read invoices"})
    %{workspace: workspace, member: member, agent: agent, account: account, task: task, run: run}
  end

  test "Moked receives a safe inventory and an expiring read-only capability", c do
    access = AgentAccess.for_member(c.workspace.id, c.member)
    assert [%{id: id, provider: "imap"}] = access.accounts
    assert id == c.account.id
    refute Map.has_key?(hd(access.accounts), :settings)
    assert {:ok, %{member: member, agent_id: nil}} = AgentAccess.authorize(access.token, "search")
    assert member.id == c.member.id
    assert {:error, :mail_access_denied} = AgentAccess.authorize(access.token, "save_attachment")
    assert {:error, :mail_access_denied} = AgentAccess.authorize(access.token, "read", c.agent.id)

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token <> "tampered", "list")

    assert {:error, :mail_access_denied} = AgentAccess.authorize(access.token, "send")
  end

  test "tokens cannot be issued using a member from a different workspace", c do
    {foreign, _} = workspace_fixture()
    assert %{unavailable: true, accounts: []} = AgentAccess.for_member(foreign.id, c.member)
  end

  test "member removal and user suspension revoke already-issued capabilities", c do
    access = AgentAccess.for_member(c.workspace.id, c.member)
    Repo.update!(Ecto.Changeset.change(c.member, status: "removed"))
    assert {:error, :mail_access_denied} = AgentAccess.authorize(access.token, "list")
    Repo.update!(Ecto.Changeset.change(c.member, status: "active"))
    user = Repo.get!(Mokaid.Accounts.User, c.member.user_id)
    Repo.update!(Ecto.Changeset.change(user, status: "disabled"))
    assert {:error, :mail_access_denied} = AgentAccess.authorize(access.token, "list")
  end

  test "expired signed claims and unsupported sources fail closed", c do
    for kind <- ["coordinator", "made-up"] do
      token =
        Phoenix.Token.sign(MokaidWeb.Endpoint, "workspace-mail-tools-v1", %{
          "kind" => kind,
          "workspace_id" => c.workspace.id,
          "member_id" => c.member.id,
          "expires_at" => System.system_time(:second) - 1
        })

      assert {:error, :mail_access_denied} = AgentAccess.authorize(token, "list")
    end
  end

  test "run scope is tied to its task, initiator, current agent and lifecycle", c do
    access = AgentAccess.for_run(c.run, c.task)

    assert {:ok, %{run_id: run_id, task_id: task_id}} =
             AgentAccess.authorize(access.token, "read", c.agent.id)

    assert run_id == c.run.id and task_id == c.task.id

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "read", Ecto.UUID.generate())

    Repo.update!(Ecto.Changeset.change(c.run, status: "canceled"))
    assert {:error, :mail_access_denied} = AgentAccess.authorize(access.token, "read", c.agent.id)
  end

  test "delegated agents retain both lead and participant tool restrictions", c do
    colleague =
      Repo.insert!(%Mokaid.Agents.Agent{
        workspace_id: c.workspace.id,
        kind: "ai",
        display_name: "Colleague",
        slug: "colleague",
        ai_enabled: true,
        status: "idle"
      })

    access = AgentAccess.for_run(c.run, c.task, [%{id: colleague.id}])
    assert {:ok, %{agent_id: actor}} = AgentAccess.authorize(access.token, "search", colleague.id)
    assert actor == colleague.id

    Repo.update!(
      Ecto.Changeset.change(colleague, tool_preferences: %{"disabled" => ["search_*"]})
    )

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "search", colleague.id)

    assert {:ok, _} = AgentAccess.authorize(access.token, "search", c.agent.id)

    Repo.update!(
      Ecto.Changeset.change(c.agent, tool_preferences: %{"disabled" => ["read_mail_*"]})
    )

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "read", colleague.id)
  end

  test "chat authority is tied to the persisted member message and conversation", c do
    {:ok, conversation} = Mokaid.AgentChat.create_conversation(c.workspace.id, c.agent.id)

    trigger =
      Repo.insert!(%Mokaid.AgentChat.ChatMessage{
        workspace_id: c.workspace.id,
        agent_id: c.agent.id,
        author_member_id: c.member.id,
        author_kind: "member",
        conversation_id: conversation.id,
        body: "Find my invoices"
      })

    access = AgentAccess.for_chat(c.workspace.id, trigger)
    assert {:ok, _} = AgentAccess.authorize(access.token, "search", c.agent.id)

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "save_attachment", c.agent.id)

    Repo.update!(Ecto.Changeset.change(conversation, status: "archived"))

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "search", c.agent.id)
  end

  test "managed recovery gets a capability but cannot read before live leases", c do
    Repo.update!(
      Ecto.Changeset.change(c.workspace,
        managed_runtime_policy: %{"enabled" => true, "data_policy_accepted" => true}
      )
    )

    Repo.insert!(%Mokaid.AI.RuntimeRun{
      workspace_id: c.workspace.id,
      run_id: c.run.id,
      budget_cents: 50,
      reserved_credits: 0
    })

    access = AgentAccess.for_run(c.run, c.task)
    assert is_binary(access.token)

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "search", c.agent.id)

    lease =
      Repo.insert!(%Mokaid.AI.RuntimeParticipant{
        workspace_id: c.workspace.id,
        run_id: c.run.id,
        agent_id: c.agent.id,
        participant_id: c.run.id,
        lease_expires_at: DateTime.add(DateTime.utc_now(), 300)
      })

    assert {:ok, _} = AgentAccess.authorize(access.token, "search", c.agent.id)
    Repo.update!(Ecto.Changeset.change(lease, released_at: DateTime.utc_now()))

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "search", c.agent.id)
  end

  test "changing role, task assignment or creator invalidates existing run capabilities", c do
    access = AgentAccess.for_run(c.run, c.task)
    {:ok, _} = Tasks.update_task(c.task, %{"assigned_agent_id" => nil})

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "search", c.agent.id)

    Repo.update!(
      Ecto.Changeset.change(c.task, assigned_agent_id: c.agent.id, created_by_member_id: nil)
    )

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "search", c.agent.id)

    Repo.update!(
      Ecto.Changeset.change(c.task,
        assigned_agent_id: c.agent.id,
        created_by_member_id: c.member.id
      )
    )

    role = Mokaid.Members.get_role_by_name(c.workspace.id, "Billing Admin")
    Repo.update!(Ecto.Changeset.change(c.member, role_id: role.id))

    assert {:error, :mail_access_denied} =
             AgentAccess.authorize(access.token, "search", c.agent.id)
  end

  test "ordinary task edits cannot replace the member authorizing mailbox access", c do
    {foreign, other} = workspace_fixture()
    other_member = owner_member(foreign, other)
    assert {:ok, task} = Tasks.update_task(c.task, %{"created_by_member_id" => other_member.id})
    assert task.created_by_member_id == c.member.id
    assert {:ok, task} = Tasks.update_task(c.task, %{created_by_member_id: nil})
    assert task.created_by_member_id == c.member.id
  end

  test "expired run checkpoints renew only the original scope after live checks", c do
    access = AgentAccess.for_run(c.run, c.task)
    salt = "workspace-mail-tools-v1"
    {:ok, claims} = Phoenix.Token.verify(MokaidWeb.Endpoint, salt, access.token, max_age: 86_400)
    expired = Map.put(claims, "expires_at", System.system_time(:second) - 1)

    old_token =
      Phoenix.Token.sign(MokaidWeb.Endpoint, salt, expired,
        signed_at: System.system_time(:second) - 86_500
      )

    assert {:error, :expired} =
             Phoenix.Token.verify(MokaidWeb.Endpoint, salt, old_token, max_age: 86_400)

    assert {:error, :mail_access_denied} = AgentAccess.authorize(old_token, "search", c.agent.id)
    assert {:ok, %{token: token}} = AgentAccess.refresh(old_token, "search", c.agent.id)
    assert {:ok, _} = AgentAccess.authorize(token, "search", c.agent.id)
    {:ok, renewed} = Phoenix.Token.verify(MokaidWeb.Endpoint, salt, token, max_age: 86_400)
    assert Map.delete(renewed, "expires_at") == Map.delete(claims, "expires_at")

    assert {:error, :mail_access_denied} =
             AgentAccess.refresh(old_token, "search", Ecto.UUID.generate())

    Repo.update!(Ecto.Changeset.change(c.agent, tool_preferences: %{"disabled" => ["search_*"]}))
    assert {:error, :mail_access_denied} = AgentAccess.refresh(old_token, "search", c.agent.id)
    assert {:ok, _} = AgentAccess.refresh(old_token, "read", c.agent.id)
    Repo.update!(Ecto.Changeset.change(c.run, status: "canceled"))
    assert {:error, :mail_access_denied} = AgentAccess.refresh(old_token, "read", c.agent.id)
  end

  test "renewal rejects conversation authority, forgery and revoked membership", c do
    access = AgentAccess.for_member(c.workspace.id, c.member)
    assert {:error, :mail_access_denied} = AgentAccess.refresh(access.token, "list")
    access = AgentAccess.for_run(c.run, c.task)
    assert {:error, :mail_access_denied} = AgentAccess.refresh(access.token <> "forged", "list")
    Repo.update!(Ecto.Changeset.change(c.member, status: "removed"))
    assert {:error, :mail_access_denied} = AgentAccess.refresh(access.token, "list", c.agent.id)
  end

  test "managed refresh requires live leases, enabled policy and a reserved runtime", c do
    enabled = %{"enabled" => true, "data_policy_accepted" => true}
    workspace = Repo.update!(Ecto.Changeset.change(c.workspace, managed_runtime_policy: enabled))

    runtime =
      Repo.insert!(%Mokaid.AI.RuntimeRun{
        workspace_id: c.workspace.id,
        run_id: c.run.id,
        budget_cents: 50,
        reserved_credits: 0
      })

    access = AgentAccess.for_run(c.run, c.task)

    {:ok, claims} =
      Phoenix.Token.verify(MokaidWeb.Endpoint, "workspace-mail-tools-v1", access.token,
        max_age: 86_400
      )

    expired =
      Phoenix.Token.sign(
        MokaidWeb.Endpoint,
        "workspace-mail-tools-v1",
        Map.put(claims, "expires_at", System.system_time(:second) - 100),
        signed_at: System.system_time(:second) - 86_500
      )

    assert {:error, :mail_access_denied} = AgentAccess.refresh(expired, "read", c.agent.id)

    lease =
      Repo.insert!(%Mokaid.AI.RuntimeParticipant{
        workspace_id: c.workspace.id,
        run_id: c.run.id,
        agent_id: c.agent.id,
        participant_id: c.run.id,
        lease_expires_at: DateTime.add(DateTime.utc_now(), 300)
      })

    assert {:ok, %{token: renewed}} = AgentAccess.refresh(expired, "read", c.agent.id)
    assert {:ok, _} = AgentAccess.authorize(renewed, "read", c.agent.id)

    lost =
      Repo.update!(
        Ecto.Changeset.change(lease, lease_expires_at: DateTime.add(DateTime.utc_now(), -1))
      )

    assert {:error, :mail_access_denied} = AgentAccess.refresh(expired, "read", c.agent.id)
    assert {:error, :mail_access_denied} = AgentAccess.authorize(renewed, "read", c.agent.id)

    Repo.update!(
      Ecto.Changeset.change(lost, lease_expires_at: DateTime.add(DateTime.utc_now(), 300))
    )

    for disabled <- [
          %{"enabled" => false, "data_policy_accepted" => true},
          %{"enabled" => true, "data_policy_accepted" => false}
        ] do
      changed = Repo.update!(Ecto.Changeset.change(workspace, managed_runtime_policy: disabled))
      assert {:error, :mail_access_denied} = AgentAccess.refresh(expired, "read", c.agent.id)
      assert {:error, :mail_access_denied} = AgentAccess.authorize(renewed, "read", c.agent.id)
      Repo.update!(Ecto.Changeset.change(changed, managed_runtime_policy: enabled))
    end

    Repo.update!(Ecto.Changeset.change(runtime, status: "pending_usage"))
    assert {:error, :mail_access_denied} = AgentAccess.refresh(expired, "read", c.agent.id)
  end
end
