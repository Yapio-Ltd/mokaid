defmodule Mokaid.Integrations.NativeGoogleIntegrationsTest do
  use Mokaid.DataCase, async: false
  use Oban.Testing, repo: Mokaid.Repo
  alias Mokaid.{Billing, Integrations, Mail, MCP, Repo}
  alias Mokaid.Integrations.{GoogleOAuth, IntegrationProvider, MailOAuthFlow}

  setup do
    previous = Application.get_env(:mokaid, :google_oauth)
    previous_http = Application.get_env(:mokaid, :google_oauth_http_options)

    Application.put_env(:mokaid, :google_oauth,
      client_id: "test-client",
      client_secret: "test-secret",
      desktop_redirect_uri: "https://mokaid.com/api/mail/oauth/google/callback"
    )

    Application.put_env(:mokaid, :google_oauth_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :google_oauth, previous)
      Application.put_env(:mokaid, :google_oauth_http_options, previous_http)
    end)

    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)

    for key <- GoogleOAuth.google_provider_keys() do
      Repo.insert!(
        %IntegrationProvider{key: key, name: key, category: "productivity", enabled: true},
        on_conflict: :nothing,
        conflict_target: :key
      )
    end

    %{workspace: workspace, member: member}
  end

  defp authorize(workspace, member, key, email, tokens \\ %{}) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/token" ->
          Req.Test.json(
            conn,
            Map.merge(
              %{
                access_token: "access-#{key}-#{email}",
                refresh_token: "refresh-#{key}-#{email}",
                scope: Enum.join(GoogleOAuth.scopes(key), " ")
              },
              tokens
            )
          )

        "/oauth2/v2/userinfo" ->
          Req.Test.json(conn, %{email: email, verified_email: true})
      end
    end)

    {:ok, started} = MailOAuthFlow.start(workspace.id, member, key)
    query = URI.decode_query(URI.parse(started.authorize_url).query)
    assert String.split(query["scope"]) == GoogleOAuth.scopes(key)
    {started, %{"state" => query["state"], "code" => "test-code"}}
  end

  test "all six native Google providers complete independently with only their own scopes", %{
    workspace: workspace,
    member: member
  } do
    Oban.Testing.with_testing_mode(:manual, fn ->
      for key <- GoogleOAuth.google_provider_keys() do
        {started, params} = authorize(workspace, member, key, "external@example.com")
        assert {:ok, :connected} = MailOAuthFlow.complete(params)

        assert {:ok,
                %{
                  status: "connected",
                  provider_key: ^key,
                  connection_id: connection_id,
                  connected_account: "external@example.com"
                } = status} =
                 MailOAuthFlow.get(workspace.id, member.id, started.flow_id, details: true)

        assert Integrations.get_connection(workspace.id, connection_id).provider.key == key
        assert is_binary(status.account_id) == (key == "gmail")
        refute Map.has_key?(status, :credentials)

        assert {:error, :not_found} =
                 MailOAuthFlow.get(workspace.id, Ecto.UUID.generate(), started.flow_id,
                   details: true
                 )
      end

      assert length(Integrations.list_connections(workspace.id)) == 6
      assert length(Mail.list_accounts(workspace.id)) == 1
      assert length(all_enqueued(worker: Mokaid.Mail.Workers.SyncWorker)) == 1
    end)
  end

  test "Google Drive requires durable credentials and denies incomplete consent", %{
    workspace: workspace,
    member: member
  } do
    {started, params} =
      authorize(workspace, member, "google_drive", "external@example.com", %{refresh_token: nil})

    assert {:error, "reconnect_with_consent"} = MailOAuthFlow.complete(params)

    assert {:ok, %{status: "failed"}} =
             MailOAuthFlow.get(workspace.id, member.id, started.flow_id)

    assert Integrations.list_connections(workspace.id) == []

    {_, params} =
      authorize(workspace, member, "google_drive", "external@example.com", %{
        scope: "openid email"
      })

    assert {:error, "integration_permission_required"} = MailOAuthFlow.complete(params)
    assert Mail.list_accounts(workspace.id) == []
  end

  test "previous broader grants satisfy new read-only service consent", %{
    workspace: workspace,
    member: member
  } do
    for {provider, broad} <- [
          {"google_drive", "drive"},
          {"google_calendar", "calendar"},
          {"google_docs", "documents"},
          {"google_sheets", "spreadsheets"}
        ] do
      {_, params} =
        authorize(workspace, member, provider, "external@example.com", %{
          scope: "https://www.googleapis.com/auth/" <> broad
        })

      assert {:ok, :connected} = MailOAuthFlow.complete(params)
    end

    assert length(Integrations.list_connections(workspace.id)) == 4
  end

  test "provider is bound to the persisted flow as well as its encrypted state", %{
    workspace: workspace,
    member: member
  } do
    {started, params} = authorize(workspace, member, "google_calendar", "external@example.com")

    Repo.get!(MailOAuthFlow, started.flow_id)
    |> Ecto.Changeset.change(provider_key: "google_drive")
    |> Repo.update!()

    assert {:error, "authorization_expired"} = MailOAuthFlow.complete(params)
    assert Integrations.list_connections(workspace.id) == []
    assert {:error, :invalid_provider} = MailOAuthFlow.start(workspace.id, member, "google_admin")
  end

  test "MCP binding preserves a different Google account and never grants agents implicitly", %{
    workspace: workspace,
    member: member
  } do
    MCP.seed_catalog()
    Billing.seed_plans()
    {:ok, _} = Billing.change_plan(workspace.id, "professional")
    {first, params} = authorize(workspace, member, "google_calendar", "first@example.com")
    assert {:ok, :connected} = MailOAuthFlow.complete(params)
    installation = MCP.get_installation_by_server_key(workspace.id, "google_calendar")
    assert installation.status == "connected"
    assert installation.connected_account == "first@example.com"
    assert is_nil(installation.encrypted_credentials)

    assert {:ok, %{mcp_status: "connected", connection_id: first_connection_id}} =
             MailOAuthFlow.get(workspace.id, member.id, first.flow_id, details: true)

    assert installation.settings["integration_connection_id"] == first_connection_id

    {second, params} = authorize(workspace, member, "google_calendar", "second@example.com")
    assert {:ok, :connected} = MailOAuthFlow.complete(params)

    assert {:ok,
            %{
              mcp_status: "different_account",
              mcp_connected_account: "first@example.com",
              connected_account: "second@example.com"
            }} =
             MailOAuthFlow.get(workspace.id, member.id, second.flow_id, details: true)

    unchanged = MCP.get_installation_by_server_key(workspace.id, "google_calendar")
    assert unchanged.connected_account == installation.connected_account
    assert unchanged.status == "connected"
    assert unchanged.settings == installation.settings
    assert Repo.aggregate(Mokaid.MCP.AgentGrant, :count) == 0
    assert length(Integrations.list_connections(workspace.id)) == 2
  end

  test "a deployment with an empty provider catalog repairs Gmail before starting consent", %{
    workspace: workspace,
    member: member
  } do
    keys = GoogleOAuth.google_provider_keys()
    providers = from p in IntegrationProvider, where: p.key in ^keys
    Repo.delete_all(providers)
    assert Repo.aggregate(providers, :count) == 0

    Oban.Testing.with_testing_mode(:manual, fn ->
      {started, params} = authorize(workspace, member, "gmail", "external@example.com")
      assert Repo.aggregate(providers, :count) == 6
      assert {:ok, :connected} = MailOAuthFlow.complete(params)

      assert {:ok, %{status: "connected", account_id: id}} =
               MailOAuthFlow.get(workspace.id, member.id, started.flow_id)

      assert Mail.get_account(workspace.id, id).email_address == "external@example.com"
    end)
  end

  test "catalog repair is idempotent and never re-enables an administrator-disabled provider", %{
    workspace: workspace,
    member: member
  } do
    provider = Integrations.get_provider_by_key("google_drive")
    Repo.update!(Ecto.Changeset.change(provider, enabled: false, name: "Restricted Drive"))
    Repo.delete_all(from p in IntegrationProvider, where: p.key == "google_sheets")
    assert :ok = Mokaid.Integrations.GoogleCatalog.seed()
    assert :ok = Mokaid.Integrations.GoogleCatalog.seed()
    keys = GoogleOAuth.google_provider_keys()
    assert Repo.aggregate(from(p in IntegrationProvider, where: p.key in ^keys), :count) == 6
    unchanged = Integrations.get_provider_by_key("google_drive")
    refute unchanged.enabled
    assert unchanged.name == "Restricted Drive"

    assert {:error, :provider_disabled} =
             MailOAuthFlow.start(workspace.id, member, "google_drive")

    refute Enum.any?(Integrations.list_providers(), &(&1.key == "google_drive"))
  end
end
