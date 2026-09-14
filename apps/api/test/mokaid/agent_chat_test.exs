defmodule Mokaid.AgentChatTest do
  # async: false — start/resume chat tasks insert Oban jobs that read the
  # global :ai_worker Application env (see WorkerClient). Keep this suite
  # sequential so a temporary :http override in another module cannot race.
  use Mokaid.DataCase, async: false

  import Mokaid.Fixtures

  alias Mokaid.AgentChat
  alias Mokaid.Agents
  alias Mokaid.Tasks

  describe "detect_mission_kind/1" do
    test "classifies website requests" do
      assert AgentChat.detect_mission_kind("Créer un site internet pour la semaine") == "website"
      assert AgentChat.detect_mission_kind("Build a landing page") == "website"
    end

    test "classifies document and analysis requests" do
      assert AgentChat.detect_mission_kind("Rédige un rapport markdown") == "document"
      assert AgentChat.detect_mission_kind("Analyse ce fichier PDF") == "analysis"
    end

    test "classifies research before logo/image keywords" do
      assert AgentChat.detect_mission_kind("Recherche BNG CPA Israel avec ce logo") ==
               "research"

      assert AgentChat.detect_mission_kind("look up Acme Corp") == "research"
    end

    test "classifies research + written report as document" do
      assert AgentChat.detect_mission_kind("Recherche BNG CPA et rédige un rapport") ==
               "document"
    end

    test "classifies avatar image requests" do
      assert AgentChat.detect_mission_kind("Modifie cet avatar") == "image"
    end

    test "falls back to general" do
      assert AgentChat.detect_mission_kind("Comment ça va ?") == "general"
    end
  end

  describe "post_agent_message/4" do
    test "malformed, deleted or wrong-agent explicit conversations never fall back to active" do
      {workspace, _owner} = workspace_fixture()

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Scoped"})

      {:ok, active} = AgentChat.create_conversation(workspace.id, agent.id)

      other =
        %Agents.Agent{}
        |> Agents.Agent.create_changeset(%{
          "workspace_id" => workspace.id,
          "kind" => "ai",
          "display_name" => "Other"
        })
        |> Repo.insert!()

      {:ok, foreign} = AgentChat.create_conversation(workspace.id, other.id)
      {:ok, deleted} = AgentChat.create_conversation(workspace.id, agent.id)
      Repo.delete!(deleted)

      for id <- ["invalid", false, deleted.id, foreign.id] do
        assert {:error, :not_found} =
                 AgentChat.post_agent_message(workspace.id, agent.id, "Never reassign",
                   conversation_id: id
                 )
      end

      assert AgentChat.list_messages_for_conversation(active.id) == []
      assert AgentChat.list_messages_for_conversation(foreign.id) == []
    end

    test "persists the reply and accepts a stream_id for broadcast" do
      {workspace, _owner} = workspace_fixture()

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{
          "kind" => "ai",
          "display_name" => "Alex",
          "ai_enabled" => true
        })

      assert {:ok, message} =
               AgentChat.post_agent_message(workspace.id, agent.id, "Voilà ton site",
                 stream_id: "stream-abc"
               )

      assert message.body == "Voilà ton site"
      assert message.author_kind == "agent"
    end

    test "targets an explicit conversation_id when provided" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{
          "kind" => "ai",
          "display_name" => "Nova",
          "ai_enabled" => true
        })

      {:ok, conv} = AgentChat.create_conversation(workspace.id, agent.id)
      {:ok, _other} = AgentChat.create_conversation(workspace.id, agent.id)

      {:ok, task} =
        Tasks.create_task(
          workspace.id,
          %{"title" => "Edit avatar", "assigned_agent_id" => agent.id},
          member
        )

      assert {:ok, message} =
               AgentChat.post_agent_message(workspace.id, agent.id, "Refus éthique",
                 conversation_id: conv.id,
                 task_id: task.id
               )

      assert message.conversation_id == conv.id
      assert message.task_id == task.id
    end
  end

  describe "start_chat_task/6" do
    test "anchors conversation_id on the task metadata" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{
          "kind" => "ai",
          "display_name" => "Nova",
          "ai_enabled" => true
        })

      {:ok, conv} = AgentChat.get_or_create_active_conversation(workspace.id, agent.id)
      message = %AgentChat.ChatMessage{body: "Ajoute une moustache", attachments: []}

      assert {:ok, task} =
               AgentChat.start_chat_task(workspace.id, agent, member, message, [], skip_ack: true)

      assert task.metadata["conversation_id"] == conv.id
      assert task.metadata["chat_agent_id"] == agent.id
      assert task.metadata["source"] == "chat"
    end
  end

  describe "resume_or_start_chat_task/6" do
    test "late execution creates and resumes only tasks from its original conversation" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Scoped"})

      {:ok, original} = AgentChat.create_conversation(workspace.id, agent.id)
      original |> Ecto.Changeset.change(status: "archived") |> Repo.update!()
      {:ok, current} = AgentChat.create_conversation(workspace.id, agent.id)

      current_message = %AgentChat.ChatMessage{
        body: "New thread work",
        conversation_id: current.id
      }

      {:ok, current_task} =
        AgentChat.start_chat_task(workspace.id, agent, member, current_message, [],
          skip_ack: true
        )

      fail_runs(workspace.id, current_task)
      late = %AgentChat.ChatMessage{body: "Old thread late work", conversation_id: original.id}

      assert {:ok, old_task} =
               AgentChat.resume_or_start_chat_task(workspace.id, agent, member, late, [],
                 skip_ack: true
               )

      refute old_task.id == current_task.id
      assert old_task.metadata["conversation_id"] == original.id
      assert Tasks.get_task(workspace.id, current_task.id).description == "New thread work"
      fail_runs(workspace.id, old_task)

      assert {:ok, resumed} =
               AgentChat.resume_or_start_chat_task(
                 workspace.id,
                 agent,
                 member,
                 %{late | body: "Continue original work"},
                 [],
                 skip_ack: true
               )

      assert resumed.id == old_task.id
      assert resumed.metadata["conversation_id"] == original.id
      assert Tasks.get_task(workspace.id, current_task.id).description == "New thread work"
    end

    test "invalid explicit conversation cannot fall back to the active thread" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Scoped"})

      message = %AgentChat.ChatMessage{
        body: "Must not create task",
        conversation_id: Ecto.UUID.generate()
      }

      assert {:error, :not_found} =
               AgentChat.start_chat_task(workspace.id, agent, member, message, [])

      assert {:error, :not_found} =
               AgentChat.resume_or_start_chat_task(workspace.id, agent, member, message, [])

      assert Repo.aggregate(from(t in Tasks.Task, where: t.workspace_id == ^workspace.id), :count) ==
               0
    end

    test "resumes a failed chat task in the same conversation instead of creating a new one" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{
          "kind" => "ai",
          "display_name" => "Nova",
          "ai_enabled" => true
        })

      message = %AgentChat.ChatMessage{body: "Ajoute une moustache", attachments: []}

      assert {:ok, task} =
               AgentChat.start_chat_task(workspace.id, agent, member, message, [], skip_ack: true)

      # Simulate handle_failure: mark any active run failed so status→to_do
      # does not try to cancel a live worker HTTP call in tests.
      for run <- Tasks.active_runs_for_task(workspace.id, task.id) do
        Tasks.update_run_progress(run, %{"status" => "failed", "error" => "content_policy: no"})
      end

      {:ok, task} = Tasks.update_task(task, %{"status" => "to_do", "progress_percent" => 0})
      task = Tasks.get_task(workspace.id, task.id)

      case task.execution_runs do
        [run | _] ->
          Tasks.update_run_progress(run, %{"status" => "failed", "error" => "content_policy: no"})

        [] ->
          {:ok, run} = Tasks.create_execution_run(task, %{"chat_task" => true})
          Tasks.update_run_progress(run, %{"status" => "failed", "error" => "content_policy: no"})
      end

      amend = %AgentChat.ChatMessage{body: "alors fais une simple moustache", attachments: []}

      assert {:ok, resumed} =
               AgentChat.resume_or_start_chat_task(workspace.id, agent, member, amend, [],
                 skip_ack: true
               )

      assert resumed.id == task.id
      assert resumed.description == "alors fais une simple moustache"
      assert resumed.metadata["instruction"] == "alors fais une simple moustache"
    end
  end

  defp fail_runs(workspace_id, task) do
    task = Tasks.get_task(workspace_id, task.id)

    runs =
      case task.execution_runs do
        [] ->
          {:ok, run} = Tasks.create_execution_run(task, %{"chat_task" => true})
          [run]

        runs ->
          runs
      end

    for run <- runs do
      Tasks.update_run_progress(run, %{"status" => "failed", "error" => "fixture failure"})
    end

    Tasks.update_task(task, %{"status" => "to_do", "progress_percent" => 0})
  end

  describe "deliver_task_output/4" do
    test "attaches drive file metadata to the chat message" do
      {workspace, _owner} = workspace_fixture()

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{
          "kind" => "ai",
          "display_name" => "Alex",
          "ai_enabled" => true
        })

      outputs = [
        %{
          "drive_item_id" => Ecto.UUID.generate(),
          "name" => "landing.html",
          "mime_type" => "text/html",
          "size_bytes" => 1200
        }
      ]

      assert {:ok, message} =
               AgentChat.deliver_task_output(
                 workspace.id,
                 agent.id,
                 "Voilà ton site",
                 outputs
               )

      assert length(message.attachments) == 1
      assert hd(message.attachments)["name"] == "landing.html"
      assert hd(message.attachments)["mime_type"] == "text/html"
    end
  end
end
