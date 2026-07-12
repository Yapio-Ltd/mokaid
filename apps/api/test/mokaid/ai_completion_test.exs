defmodule Mokaid.AICompletionTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.{AI, Agents, Drive, Tasks}
  alias Mokaid.AgentChat.ChatMessage

  defp setup_run!(attrs \\ %{}) do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)

    {:ok, agent} =
      Agents.create_agent(workspace.id, %{
        "kind" => "ai",
        "display_name" => "Alex",
        "ai_enabled" => true
      })

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => Map.get(attrs, :title, "Site internet"),
          "description" => Map.get(attrs, :description, "Créer un site"),
          "assigned_agent_id" => agent.id,
          "metadata" => %{
            "source" => "chat",
            "chat_agent_id" => agent.id,
            "language" => Map.get(attrs, :language, "fr"),
            "mission_kind" => Map.get(attrs, :mission_kind, "website"),
            "instruction" => Map.get(attrs, :description, "Créer un site")
          }
        },
        member
      )

    {:ok, run} = Tasks.create_execution_run(task, %{"chat_task" => true})
    %{workspace: workspace, member: member, agent: agent, task: task, run: run}
  end

  test "completion without artifacts stays in_progress and skips chat Done" do
    %{agent: agent, task: task, run: run} = setup_run!()

    assert {:ok, _} =
             AI.handle_completion(run.id, %{"summary" => "Need more info", "artifacts" => []})

    updated_task = Tasks.get_task(task.workspace_id, task.id)
    assert updated_task.status == "in_progress"
    assert updated_task.progress_percent != 100

    messages =
      Repo.all(
        from m in ChatMessage,
          where: m.workspace_id == ^task.workspace_id and m.agent_id == ^agent.id
      )

    refute Enum.any?(messages, &String.contains?(&1.body || "", "Voilà"))
    refute Enum.any?(messages, &String.contains?(&1.body || "", "Here's what"))
  end

  test "completion with HTML drive output delivers chat attachment and marks in_review" do
    %{workspace: workspace, agent: agent, task: task, run: run} = setup_run!()

    {:ok, file} =
      Drive.create_file(workspace.id, %{
        "name" => "landing.html",
        "slug" => "landing-html-#{System.unique_integer([:positive])}",
        "mime_type" => "text/html",
        "extension" => "html",
        "size_bytes" => 42,
        "storage_key" => "test/landing-#{System.unique_integer([:positive])}.html",
        "checksum" => "abc",
        "linked_task_id" => task.id,
        "created_by_agent_id" => agent.id
      })

    assert {:ok, _} =
             AI.handle_completion(run.id, %{
               "summary" => "Site ready",
               "artifacts" => [file.name]
             })

    updated_task = Tasks.get_task(workspace.id, task.id)
    assert updated_task.status == "in_review"
    assert updated_task.progress_percent == 100

    messages =
      Repo.all(
        from m in ChatMessage,
          where: m.workspace_id == ^workspace.id and m.agent_id == ^agent.id,
          order_by: [asc: m.inserted_at]
      )

    delivery = Enum.find(messages, &String.contains?(&1.body || "", "site"))
    assert delivery
    assert Enum.any?(delivery.attachments, &(&1["drive_item_id"] == file.id))
    assert Enum.any?(delivery.attachments, &(&1["mime_type"] == "text/html"))
  end
end
