defmodule Mokaid.MCPTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.{Agents, Fixtures, MCP}

  setup do
    MCP.seed_catalog()
    {workspace, owner} = Fixtures.workspace_fixture()
    member = Fixtures.owner_member(workspace, owner)

    {:ok, agent} =
      Agents.create_agent(
        workspace.id,
        %{"display_name" => "Test Agent", "role" => "Tester", "kind" => "ai"},
        member
      )

    %{workspace: workspace, member: member, agent: agent}
  end

  test "catalog is seeded and idempotent" do
    servers = MCP.list_servers()
    assert length(servers) > 50
    assert Enum.any?(servers, &(&1.key == "figma"))

    # Rerunning must not duplicate entries.
    assert :ok = MCP.seed_catalog()
    assert length(MCP.list_servers()) == length(servers)
  end

  test "install with api key encrypts credentials and connects", %{
    workspace: workspace,
    member: member
  } do
    {:ok, installation} =
      MCP.install(workspace.id, "notion", member, %{
        "credentials" => %{"api_key" => "secret-key-123"}
      })

    assert installation.status == "connected"
    assert installation.encrypted_credentials
    refute installation.encrypted_credentials =~ "secret-key-123"

    assert {:ok, %{"api_key" => "secret-key-123"}} =
             {:ok, MCP.decrypted_credentials(installation)}
  end

  test "oauth servers install as pending until credentials are stored", %{
    workspace: workspace,
    member: member
  } do
    {:ok, installation} = MCP.install(workspace.id, "figma", member)
    assert installation.status == "pending"

    {:ok, connected} =
      MCP.store_credentials(installation, %{"access_token" => "tok"}, "design@acme.com")

    assert connected.status == "connected"
    assert connected.connected_account == "design@acme.com"
  end

  test "install unknown server fails", %{workspace: workspace, member: member} do
    assert {:error, :server_not_found} = MCP.install(workspace.id, "does-not-exist", member)
  end

  test "agent grants gate authorized_servers_for_agent", %{
    workspace: workspace,
    member: member,
    agent: agent
  } do
    {:ok, installation} =
      MCP.install(workspace.id, "github", member, %{
        "credentials" => %{"api_key" => "gh-token"}
      })

    # No grant yet: nothing is authorized.
    assert MCP.authorized_servers_for_agent(workspace.id, agent.id) == []

    {:ok, _grant} = MCP.set_grant(workspace.id, agent.id, installation.id, true, member)

    assert [server] = MCP.authorized_servers_for_agent(workspace.id, agent.id)
    assert server.key == "github"
    assert server.credentials == %{"api_key" => "gh-token"}
    assert server.url

    # Revoking removes access.
    {:ok, _} = MCP.set_grant(workspace.id, agent.id, installation.id, false, member)
    assert MCP.authorized_servers_for_agent(workspace.id, agent.id) == []
  end

  test "uninstall removes the installation and grants", %{
    workspace: workspace,
    member: member,
    agent: agent
  } do
    {:ok, installation} =
      MCP.install(workspace.id, "linear", member, %{
        "credentials" => %{"api_key" => "lin-token"}
      })

    {:ok, _} = MCP.set_grant(workspace.id, agent.id, installation.id, true, member)
    {:ok, _} = MCP.uninstall(installation, member)

    assert MCP.get_installation(workspace.id, installation.id) == nil
    assert MCP.authorized_servers_for_agent(workspace.id, agent.id) == []
  end
end
