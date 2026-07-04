defmodule Mokaid.AgentsTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Agents

  describe "create_agent/3" do
    test "creates an AI agent without a linked user" do
      {workspace, _owner} = workspace_fixture()

      assert {:ok, agent} =
               Agents.create_agent(workspace.id, %{
                 "kind" => "ai",
                 "display_name" => "Data Analyst",
                 "ai_enabled" => true
               })

      assert agent.kind == "ai"
      assert agent.linked_user_id == nil
      assert agent.slug =~ "data-analyst"
    end

    test "rejects a human_linked agent without a linked user" do
      {workspace, _owner} = workspace_fixture()

      assert {:error, changeset} =
               Agents.create_agent(workspace.id, %{
                 "kind" => "human_linked",
                 "display_name" => "Ava"
               })

      assert %{linked_user_id: _} = errors_on(changeset)
    end

    test "rejects an AI agent with a linked user" do
      {workspace, owner} = workspace_fixture()

      assert {:error, changeset} =
               Agents.create_agent(workspace.id, %{
                 "kind" => "ai",
                 "display_name" => "Bot",
                 "linked_user_id" => owner.id
               })

      assert %{linked_user_id: _} = errors_on(changeset)
    end
  end

  describe "change_status/3" do
    test "records a status event" do
      {workspace, _owner} = workspace_fixture()

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Bot"})

      assert {:ok, updated} = Agents.change_status(agent, "busy", reason: "task_assigned")
      assert updated.status == "busy"

      events = Repo.all(Mokaid.Agents.AgentStatusEvent)
      assert Enum.any?(events, &(&1.to_status == "busy"))
    end
  end

  describe "workspace scoping" do
    test "agents are not visible across workspaces" do
      {workspace_a, _} = workspace_fixture()
      {workspace_b, _} = workspace_fixture()

      {:ok, agent} =
        Agents.create_agent(workspace_a.id, %{"kind" => "ai", "display_name" => "Bot A"})

      assert Agents.get_agent(workspace_b.id, agent.id) == nil
      assert [] = Agents.list_agents(workspace_b.id)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
