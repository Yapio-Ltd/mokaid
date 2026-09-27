defmodule Mokaid.MCPGoogleTest do
  use Mokaid.DataCase, async: false

  alias Mokaid.{Agents, Billing, Integrations, MCP, Repo, Vault}
  alias Mokaid.Integrations.{IntegrationConnection, IntegrationProvider}
  alias Mokaid.MCP.{AgentGrant, Installation, Server}

  setup do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)

    {:ok, agent} =
      Agents.create_agent(workspace.id, %{"display_name" => "Reader", "kind" => "ai"}, member)

    server =
      Repo.insert!(
        %Server{
          key: "google_drive",
          name: "Drive",
          auth_kind: "oauth2",
          category: "storage",
          enabled: true
        },
        on_conflict: {:replace, [:name, :enabled]},
        conflict_target: :key,
        returning: true
      )

    provider =
      Repo.insert!(
        %IntegrationProvider{
          key: "google_drive",
          name: "Drive",
          category: "storage",
          enabled: true
        },
        on_conflict: {:replace, [:name, :enabled]},
        conflict_target: :key,
        returning: true
      )

    credentials = %{
      "access_token" => "live-access",
      "refresh_token" => "private-refresh",
      "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600)),
      "scope" => "https://www.googleapis.com/auth/drive.readonly"
    }

    connection =
      Repo.insert!(%IntegrationConnection{
        workspace_id: workspace.id,
        provider_id: provider.id,
        connected_account: "external@example.com",
        status: "connected",
        encrypted_credentials: Vault.encrypt(credentials)
      })

    installation =
      Repo.insert!(%Installation{
        workspace_id: workspace.id,
        server_id: server.id,
        connected_account: "EXTERNAL@example.com",
        status: "connected",
        settings: %{
          "integration_connection_id" => connection.id,
          "server_url" => "https://untrusted.test"
        },
        encrypted_credentials: Vault.encrypt(%{"access_token" => "stale-duplicate"})
      })

    %{
      workspace: workspace,
      member: member,
      agent: agent,
      installation: installation,
      connection: connection,
      provider: provider,
      credentials: credentials
    }
  end

  defp allow(context) do
    {:ok, _} =
      MCP.set_grant(
        context.workspace.id,
        context.agent.id,
        context.installation.id,
        true,
        context.member
      )
  end

  defp resolve(context),
    do: MCP.authorized_servers_for_agent(context.workspace.id, context.agent.id, "google_drive")

  test "native tools require explicit grants and expose only the live exact account token",
       context do
    assert resolve(context) == []
    allow(context)
    assert [descriptor] = resolve(context)
    assert descriptor.transport == "google"
    assert descriptor.url == ""
    assert descriptor.credentials["access_token"] == "live-access"
    refute Map.has_key?(descriptor.credentials, "refresh_token")

    {:ok, _} =
      Integrations.store_credentials(
        context.connection,
        Map.put(context.credentials, "access_token", "rotated")
      )

    assert [descriptor] = resolve(context)
    assert descriptor.credentials["access_token"] == "rotated"

    {:ok, _} =
      MCP.set_grant(
        context.workspace.id,
        context.agent.id,
        context.installation.id,
        false,
        context.member
      )

    assert resolve(context) == []
  end

  test "wrong account or explicit pointer never falls back to a usable connection", context do
    allow(context)

    for change <- [
          [connected_account: "different@example.com"],
          [settings: %{"integration_connection_id" => Ecto.UUID.generate()}],
          [settings: %{"integration_connection_id" => "malformed"}],
          [status: "disconnected"]
        ] do
      Repo.update!(Ecto.Changeset.change(context.installation, change))
      assert resolve(context) == []

      Repo.update!(
        Ecto.Changeset.change(Repo.get!(Installation, context.installation.id),
          connected_account: context.installation.connected_account,
          settings: context.installation.settings,
          status: "connected"
        )
      )
    end
  end

  test "provider, workspace and connection status are checked", context do
    allow(context)
    {other_workspace, _} = workspace_fixture()

    for change <- [
          [workspace_id: other_workspace.id],
          [status: "disconnected"],
          [connected_account: "different@example.com"]
        ] do
      Repo.update!(Ecto.Changeset.change(context.connection, change))
      assert resolve(context) == []

      Repo.update!(
        Ecto.Changeset.change(Repo.get!(IntegrationConnection, context.connection.id),
          workspace_id: context.workspace.id,
          status: "connected",
          connected_account: context.connection.connected_account
        )
      )
    end

    Repo.update!(Ecto.Changeset.change(context.provider, enabled: false))
    assert resolve(context) == []
  end

  test "legacy pointer-free installs resolve only an unambiguous exact account", context do
    allow(context)
    Repo.update!(Ecto.Changeset.change(context.installation, settings: %{}))
    assert [_] = resolve(context)

    Repo.insert!(%IntegrationConnection{
      workspace_id: context.workspace.id,
      provider_id: context.provider.id,
      connected_account: "EXTERNAL@example.com",
      status: "connected",
      encrypted_credentials: context.connection.encrypted_credentials
    })

    assert resolve(context) == []
  end

  defp refreshing(context, callback) do
    previous = Application.get_env(:mokaid, :google_oauth)
    previous_http = Application.get_env(:mokaid, :google_oauth_http_options)

    Application.put_env(:mokaid, :google_oauth,
      client_id: "test-client",
      client_secret: "test-secret"
    )

    Application.put_env(:mokaid, :google_oauth_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :google_oauth, previous)
      Application.put_env(:mokaid, :google_oauth_http_options, previous_http)
    end)

    {:ok, _} =
      Integrations.store_credentials(
        context.connection,
        Map.put(
          context.credentials,
          "expires_at",
          DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60))
        )
      )

    Req.Test.stub(__MODULE__, fn conn ->
      callback.()
      Req.Test.json(conn, %{access_token: "fresh-access", expires_in: 3600})
    end)
  end

  test "expired token is refreshed before handing it to the worker", context do
    allow(context)
    refreshing(context, fn -> :ok end)
    assert [descriptor] = resolve(context)
    assert descriptor.credentials["access_token"] == "fresh-access"
    refute Map.has_key?(descriptor.credentials, "refresh_token")
  end

  test "grant revoked during token refresh is not returned", context do
    allow(context)

    refreshing(context, fn ->
      {:ok, _} =
        MCP.set_grant(
          context.workspace.id,
          context.agent.id,
          context.installation.id,
          false,
          context.member
        )
    end)

    assert resolve(context) == []
  end

  test "account disconnected during refresh is not resurrected", context do
    allow(context)

    refreshing(context, fn ->
      Repo.update!(
        Ecto.Changeset.change(context.connection,
          status: "disconnected",
          encrypted_credentials: nil
        )
      )
    end)

    assert resolve(context) == []
    assert Repo.get!(IntegrationConnection, context.connection.id).encrypted_credentials == nil
  end

  test "account binding changed during refresh fails closed", context do
    allow(context)

    refreshing(context, fn ->
      Repo.update!(
        Ecto.Changeset.change(context.installation, connected_account: "other@example.com")
      )
    end)

    assert resolve(context) == []
  end

  test "ensuring OAuth install preserves existing identity, credentials, settings and grants",
       context do
    allow(context)

    assert {:ok, existing} =
             MCP.ensure_oauth_installation(context.workspace.id, "google_drive", context.member)

    for field <- [:id, :status, :connected_account, :encrypted_credentials, :settings] do
      assert Map.get(existing, field) == Map.get(context.installation, field)
    end

    assert Repo.aggregate(AgentGrant, :count) == 1
  end

  test "new OAuth install checks plan and starts without an account or grants", context do
    Repo.delete!(context.installation)
    Billing.seed_plans()

    assert {:error, :mcp_integration_limit_reached} =
             MCP.ensure_oauth_installation(context.workspace.id, "google_drive", context.member)

    {:ok, _} = Billing.change_plan(context.workspace.id, "professional")

    assert {:ok, pending} =
             MCP.ensure_oauth_installation(context.workspace.id, "google_drive", context.member)

    assert pending.status == "pending"
    assert pending.connected_account == nil
    assert pending.encrypted_credentials == nil
    assert Repo.aggregate(AgentGrant, :count) == 0
  end
end
