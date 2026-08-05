defmodule Mokaid.WorkspacesTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.{Agents, Billing, Fixtures, Workspaces}

  setup do
    Billing.seed_plans()
    :ok
  end

  describe "workspace bootstrap" do
    test "a new workspace ships with a Free subscription and a first AI employee" do
      user = Fixtures.user_fixture()

      {:ok, workspace} = Workspaces.create_workspace(%{"name" => "Acme"}, user)

      subscription = Billing.get_subscription(workspace.id)
      assert subscription.plan.key == "free"
      assert subscription.status == "active"

      assert [agent] = Agents.list_agents(workspace.id)
      assert agent.kind == "ai"
      assert agent.capabilities["bootstrap"] == true
    end

    test "creating a custom agent at the limit replaces the untouched placeholder" do
      user = Fixtures.user_fixture()
      {:ok, workspace} = Workspaces.create_workspace(%{"name" => "Acme"}, user)

      # Free plan: 1 agent — the bootstrap placeholder occupies the only slot.
      assert Billing.agent_limit(workspace.id) == 1
      [placeholder] = Agents.list_agents(workspace.id)

      {:ok, custom} =
        Agents.create_agent(workspace.id, %{
          "display_name" => "My Analyst",
          "kind" => "ai"
        })

      # list_agents excludes archived agents — only the custom one remains.
      assert Agents.list_agents(workspace.id) |> Enum.map(& &1.id) == [custom.id]

      archived = Agents.get_agent(workspace.id, placeholder.id)
      assert archived.archived_at != nil
      assert archived.seat_index == nil
    end

    test "a placeholder that has done real work is not silently replaced" do
      user = Fixtures.user_fixture()
      {:ok, workspace} = Workspaces.create_workspace(%{"name" => "Acme"}, user)

      [placeholder] = Agents.list_agents(workspace.id)

      {:ok, _} =
        placeholder
        |> Ecto.Changeset.change(missions_completed: 3)
        |> Mokaid.Repo.update()

      assert {:error, :agent_limit_reached} =
               Agents.create_agent(workspace.id, %{
                 "display_name" => "Second Agent",
                 "kind" => "ai"
               })
    end

    test "bootstrap: false yields a bare workspace (tests/admin tooling)" do
      user = Fixtures.user_fixture()

      {:ok, workspace} =
        Workspaces.create_workspace(%{"name" => "Bare"}, user, bootstrap: false)

      assert Agents.list_agents(workspace.id) == []
    end
  end
end
