defmodule Mokaid.AI.DispatcherTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Agents
  alias Mokaid.AI.Dispatcher
  alias Mokaid.Billing
  alias Mokaid.Drive
  alias Mokaid.Repo
  alias Mokaid.Tasks

  setup do
    Billing.seed_plans()
    :ok
  end

  defp create_agent(workspace_id, name, role, skills) do
    Billing.change_plan(workspace_id, "professional")

    {:ok, agent} =
      Agents.create_agent(workspace_id, %{
        "kind" => "ai",
        "display_name" => name,
        "role_title" => role,
        "archetype_key" => "generalist"
      })

    {:ok, agent} =
      Agents.apply_internal_update(agent, %{
        "skills" => Enum.map(skills, &%{"name" => &1, "level" => 80}),
        "role_title" => role
      })

    agent
  end

  describe "analyze/2" do
    test "rejects an empty request" do
      {workspace, _owner} = workspace_fixture()
      assert {:error, :empty_request} = Dispatcher.analyze(workspace.id, %{"instruction" => "  "})
    end

    test "recommends the agent whose skills match the instruction" do
      {workspace, _owner} = workspace_fixture()
      designer = create_agent(workspace.id, "Mia", "Designer", ["figma", "branding", "design"])
      _writer = create_agent(workspace.id, "Leo", "Writer", ["writing", "editing"])

      assert {:ok, analysis} =
               Dispatcher.analyze(workspace.id, %{
                 "instruction" => "Review this figma design and improve the branding"
               })

      assert analysis.recommendation.mode in ["existing_agent", "user_choice"]
      assert analysis.recommendation.agent_id == designer.id
      assert analysis.task.title =~ "figma"
    end

    test "proposes a custom agent when nobody matches" do
      {workspace, _owner} = workspace_fixture()
      _writer = create_agent(workspace.id, "Leo", "Writer", ["writing"])

      assert {:ok, analysis} =
               Dispatcher.analyze(workspace.id, %{
                 "instruction" => "zzqx unmatched request",
                 "files" => [%{"name" => "dataset.csv"}]
               })

      assert analysis.recommendation.mode == "custom_agent"
      assert analysis.recommendation.agent_id == nil
      assert analysis.recommendation.alternatives == []
      assert analysis.recommendation.custom_agent.display_name == "Data Scientist"
      assert analysis.recommendation.custom_agent.archetype_key == "data_scientist"
    end

    test "does not force-fit an agent on a vague request with no domain signal" do
      {workspace, _owner} = workspace_fixture()

      _engineer =
        create_agent(workspace.id, "Sira", "Software Engineer", [
          "coding",
          "debugging",
          "code-review",
          "architecture"
        ])

      assert {:ok, analysis} =
               Dispatcher.analyze(workspace.id, %{
                 "instruction" => "tu pense quoi de ca"
               })

      assert analysis.recommendation.mode == "custom_agent"
      assert analysis.recommendation.agent_id == nil
      assert analysis.recommendation.alternatives == []
      assert analysis.recommendation.custom_agent != nil
      assert is_binary(analysis.recommendation.custom_agent.display_name)
    end

    test "exposes the requested domain categories" do
      {workspace, _owner} = workspace_fixture()
      _writer = create_agent(workspace.id, "Leo", "Writer", ["writing"])

      assert {:ok, analysis} =
               Dispatcher.analyze(workspace.id, %{
                 "instruction" => "Redesign our logo with a modern branding"
               })

      assert "design" in analysis.domain_categories
    end

    test "routes ecommerce site building to the software engineer, not legal" do
      {workspace, _owner} = workspace_fixture()

      engineer =
        create_agent(workspace.id, "Sira", "Software Engineer", [
          "coding",
          "debugging",
          "code-review",
          "architecture"
        ])

      _legal =
        create_agent(workspace.id, "Taya", "Legal Specialist", [
          "contracts",
          "compliance",
          "legal-research",
          "risk"
        ])

      assert {:ok, analysis} =
               Dispatcher.analyze(workspace.id, %{
                 "instruction" =>
                   "Jaimerai que tu fasse un site ecommerce entier pour vendre des tables"
               })

      assert "code" in analysis.domain_categories
      assert analysis.recommendation.agent_id == engineer.id
      assert analysis.recommendation.mode in ["existing_agent", "user_choice"]
      assert analysis.recommendation.confidence >= 60
    end

    test "detects urgency and derives a bounded title" do
      {workspace, _owner} = workspace_fixture()
      long = String.duplicate("very long instruction ", 20)

      assert {:ok, analysis} =
               Dispatcher.analyze(workspace.id, %{"instruction" => "URGENT: " <> long})

      assert analysis.task.priority == "urgent"
      assert String.length(analysis.task.title) <= 80
    end
  end

  describe "attachment-aware routing" do
    test "recognizes uppercase extensions and prioritizes requested specialty" do
      {workspace, _owner} = workspace_fixture()

      assert {:ok, analysis} =
               Dispatcher.analyze(workspace.id, %{
                 "instruction" => "Perform a legal review",
                 "files" => [%{"name" => "AGREEMENT.PDF"}]
               })

      assert analysis.domain_categories == ["legal", "document"]
      assert analysis.recommendation.custom_agent.archetype_key == "legal"
    end

    test "does not recommend disabled employees" do
      {workspace, _owner} = workspace_fixture()
      agent = create_agent(workspace.id, "Mia", "Designer", ["design"])
      {:ok, _} = Agents.apply_internal_update(agent, %{"ai_enabled" => false})

      assert {:ok, analysis} =
               Dispatcher.analyze(workspace.id, %{"instruction" => "Create a logo design"})

      assert analysis.recommendation.mode == "custom_agent"
      assert analysis.recommendation.agent_id == nil
    end
  end

  describe "confirm/3" do
    test "creates the task assigned to an existing agent and starts a run" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)
      agent = create_agent(workspace.id, "Mia", "Designer", ["design"])

      assert {:ok, %{task: task, agent: assigned, run: run}} =
               Dispatcher.confirm(workspace.id, member, %{
                 "instruction" => "Design a landing page",
                 "agent_id" => agent.id,
                 "start_now" => true
               })

      assert task.assigned_agent_id == agent.id
      assert assigned.id == agent.id
      assert task.metadata["source"] == "dispatch"
      assert run != nil
      assert run.task_id == task.id
    end

    test "persists the capability match snapshot and requested domains" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)
      agent = create_agent(workspace.id, "Leo", "Writer", ["writing"])

      assert {:ok, %{task: task}} =
               Dispatcher.confirm(workspace.id, member, %{
                 "instruction" => "Redesign our logo",
                 "agent_id" => agent.id,
                 "capability_match" => %{
                   "mode" => "user_choice",
                   "confidence" => 30,
                   "reason" => "Leo can handle it, but a design agent would fit better.",
                   "warning_shown" => true,
                   "unexpected" => "dropped"
                 }
               })

      assert task.metadata["domain_requested"] == ["design"]

      match = task.metadata["capability_match"]
      assert match["mode"] == "user_choice"
      assert match["confidence"] == 30
      assert match["warning_shown"] == true
      refute Map.has_key?(match, "unexpected")
    end

    test "creates a custom agent on demand via archetype" do
      {workspace, owner} = workspace_fixture()
      Billing.change_plan(workspace.id, "professional")
      member = owner_member(workspace, owner)

      assert {:ok, %{task: task, agent: agent}} =
               Dispatcher.confirm(workspace.id, member, %{
                 "instruction" => "Analyze this dataset",
                 "custom_agent" => %{
                   "display_name" => "Data Analyst",
                   "role_title" => "Data Analysis Specialist",
                   "archetype_key" => "data_analyst",
                   "skills" => [%{"name" => "data-analysis", "level" => 75}]
                 }
               })

      assert agent.kind == "ai"
      assert agent.ai_enabled
      assert agent.display_name == "Data Analyst"
      assert Enum.any?(agent.skills, &(&1["name"] == "data-analysis"))
      refute Enum.any?(agent.skills, &(&1["level"] == 75))
      assert task.assigned_agent_id == agent.id
    end

    test "replays confirmation without creating duplicate tasks, agents, or runs" do
      {workspace, owner} = workspace_fixture()
      Billing.change_plan(workspace.id, "professional")
      member = owner_member(workspace, owner)

      params = %{
        "client_request_id" => Ecto.UUID.generate(),
        "instruction" => "Summarize the report",
        "custom_agent" => %{
          "display_name" => "Lena",
          "archetype_key" => "writer",
          "instructions" => "Always cite the attached source documents."
        }
      }

      assert {:ok, first} = Dispatcher.confirm(workspace.id, member, params)
      assert {:ok, replay} = Dispatcher.confirm(workspace.id, member, params)
      assert first.task.id == replay.task.id
      assert first.agent.id == replay.agent.id
      assert first.run.id == replay.run.id
      assert length(Tasks.list_tasks(workspace.id)) == 1
      assert length(Agents.list_agents(workspace.id)) == 1
      assert first.agent.instructions == "Always cite the attached source documents."
      assert length(Tasks.list_runs_for_task(workspace.id, first.task.id)) == 1

      assert {:error, :request_id_conflict} =
               Dispatcher.confirm(
                 workspace.id,
                 member,
                 Map.put(params, "instruction", "Changed request")
               )

      assert length(Tasks.list_tasks(workspace.id)) == 1
    end

    test "scopes confirmation keys to the workspace" do
      {workspace, owner} = workspace_fixture()
      {other_workspace, other_owner} = workspace_fixture()

      params = %{
        "client_request_id" => Ecto.UUID.generate(),
        "instruction" => "Draft report",
        "start_now" => false
      }

      assert {:ok, first} =
               Dispatcher.confirm(workspace.id, owner_member(workspace, owner), params)

      assert {:ok, other} =
               Dispatcher.confirm(
                 other_workspace.id,
                 owner_member(other_workspace, other_owner),
                 params
               )

      refute first.task.id == other.task.id
      assert other.task.workspace_id == other_workspace.id
    end

    test "retains arbitrary file types, deduplicates uploads, and derives a readable title" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, file} =
        Drive.create_file(
          workspace.id,
          %{
            "name" => "project.custom-format",
            "storage_key" => "workspaces/#{workspace.id}/drive/input",
            "mime_type" => "application/octet-stream"
          },
          member
        )

      assert {:ok, %{task: task}} =
               Dispatcher.confirm(workspace.id, member, %{
                 "drive_item_ids" => [file.id, file.id],
                 "start_now" => false
               })

      assert task.title == "Process project.custom-format"
      assert task.metadata["drive_item_ids"] == [file.id]
      assert [%{id: id, is_ai_readable: true}] = task.drive_items
      assert id == file.id
      assert Drive.get_item(workspace.id, file.id).linked_task_id == task.id
    end

    test "rejects unavailable, foreign, folder, and malformed attachments before creating an agent" do
      {workspace, owner} = workspace_fixture()
      {other, _} = workspace_fixture()
      Billing.change_plan(workspace.id, "professional")
      member = owner_member(workspace, owner)

      {:ok, foreign} =
        Drive.create_file(other.id, %{"name" => "secret.pdf", "storage_key" => "other/input"})

      {:ok, folder} = Drive.create_folder(workspace.id, %{"name" => "Folder"})

      {:ok, trashed} =
        Drive.create_file(workspace.id, %{"name" => "old.pdf", "storage_key" => "old/input"})

      {:ok, _} = Drive.trash_item(trashed, member)

      for ids <- [
            [foreign.id],
            [folder.id],
            [trashed.id],
            [Ecto.UUID.generate()],
            ["invalid"],
            "invalid"
          ] do
        assert {:error, :invalid_attachments} =
                 Dispatcher.confirm(workspace.id, member, %{
                   "instruction" => "Read this document",
                   "drive_item_ids" => ids,
                   "custom_agent" => %{"display_name" => "Lena", "archetype_key" => "writer"}
                 })
      end

      assert Tasks.list_tasks(workspace.id) == []
      assert Agents.list_agents(workspace.id) == []
      assert Dispatcher.attached_files(workspace.id, [trashed.id]) == []
    end

    test "rolls back the custom agent and mission when execution cannot start" do
      {workspace, owner} = workspace_fixture()
      Billing.change_plan(workspace.id, "professional")
      member = owner_member(workspace, owner)
      subscription = Repo.get_by!(Mokaid.Billing.Subscription, workspace_id: workspace.id)

      subscription
      |> Ecto.Changeset.change(included_credits_remaining: 0, credits_balance: 0)
      |> Repo.update!()

      request_id = Ecto.UUID.generate()

      params = %{
        "client_request_id" => request_id,
        "instruction" => "Write a concise summary",
        "custom_agent" => %{"display_name" => "Lena", "archetype_key" => "writer"}
      }

      assert {:error, :insufficient_credits} = Dispatcher.confirm(workspace.id, member, params)
      assert Tasks.list_tasks(workspace.id) == []
      assert Agents.list_agents(workspace.id) == []

      subscription |> Ecto.Changeset.change(credits_balance: 100) |> Repo.update!()
      assert {:ok, %{run: run}} = Dispatcher.confirm(workspace.id, member, params)
      assert run != nil
    end

    test "rejects empty requests and missing or disabled employees instead of false success" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)
      assert {:error, :empty_request} = Dispatcher.confirm(workspace.id, member, %{})

      assert {:error, :no_agent_assigned} =
               Dispatcher.confirm(workspace.id, member, %{"instruction" => "Write a report"})

      agent = create_agent(workspace.id, "Mia", "Designer", ["design"])
      {:ok, _} = Agents.apply_internal_update(agent, %{"ai_enabled" => false})

      assert {:error, :agent_unavailable} =
               Dispatcher.confirm(workspace.id, member, %{
                 "instruction" => "Design a logo",
                 "agent_id" => agent.id
               })

      assert Tasks.list_tasks(workspace.id) == []
    end

    test "rejects a malformed retry key and unknown integrations" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      assert {:error, :invalid_request_id} =
               Dispatcher.confirm(workspace.id, member, %{
                 "client_request_id" => "invalid",
                 "instruction" => "Write a report",
                 "start_now" => false
               })

      assert {:error, :invalid_integrations} =
               Dispatcher.confirm(workspace.id, member, %{
                 "instruction" => "Write a report",
                 "start_now" => false,
                 "grant_installation_ids" => [Ecto.UUID.generate()]
               })

      assert Tasks.list_tasks(workspace.id) == []
    end

    test "rejects an agent from another workspace" do
      {workspace, owner} = workspace_fixture()
      {other_workspace, _} = workspace_fixture()
      member = owner_member(workspace, owner)
      foreign_agent = create_agent(other_workspace.id, "Spy", "Agent", [])

      assert {:error, :agent_not_found} =
               Dispatcher.confirm(workspace.id, member, %{
                 "instruction" => "Do something",
                 "agent_id" => foreign_agent.id
               })
    end
  end
end
