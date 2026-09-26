defmodule Mokaid.Integrations.MailOAuthFlowTest do
  use Mokaid.DataCase, async: false
  use Oban.Testing, repo: Mokaid.Repo
  import Mokaid.Fixtures
  alias Mokaid.{Integrations, Repo}
  alias Mokaid.Integrations.{IntegrationProvider, MailOAuthFlow}

  @redirect "https://mokaid.com/api/mail/oauth/google/callback"
  @scope "https://www.googleapis.com/auth/gmail.modify"

  setup do
    previous = Application.get_env(:mokaid, :google_oauth)
    previous_http = Application.get_env(:mokaid, :google_oauth_http_options, [])

    Application.put_env(:mokaid, :google_oauth,
      client_id: "test-client",
      client_secret: "test-secret",
      desktop_redirect_uri: @redirect
    )

    Application.put_env(:mokaid, :google_oauth_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :google_oauth, previous)
      Application.put_env(:mokaid, :google_oauth_http_options, previous_http)
    end)

    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)

    Repo.insert!(
      %IntegrationProvider{key: "gmail", name: "Gmail", category: "communication", enabled: true},
      on_conflict: :nothing,
      conflict_target: :key
    )

    %{workspace: workspace, member: member}
  end

  defp authorize(workspace, member, email, refresh \\ "refresh") do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/token" ->
          Req.Test.json(conn, %{
            access_token: "access-#{email}",
            refresh_token: refresh,
            scope: @scope
          })

        "/oauth2/v2/userinfo" ->
          Req.Test.json(conn, %{email: email, verified_email: true})
      end
    end)

    {:ok, started} = MailOAuthFlow.start(workspace.id, member)
    state = URI.decode_query(URI.parse(started.authorize_url).query)["state"]
    {started, %{"state" => state, "code" => "code"}}
  end

  test "native consent connects two independent Gmail accounts, queues initial sync, and rejects replay",
       %{workspace: workspace, member: member} do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {first, params} = authorize(workspace, member, "first@example.com")

      assert {:ok, %{status: "pending"}} =
               MailOAuthFlow.get(workspace.id, member.id, first.flow_id)

      assert {:error, :not_found} =
               MailOAuthFlow.get(workspace.id, Ecto.UUID.generate(), first.flow_id)

      assert {:ok, :connected} = MailOAuthFlow.complete(params)

      assert {:ok, %{status: "connected", account_id: first_id}} =
               MailOAuthFlow.get(workspace.id, member.id, first.flow_id)

      assert {:error, "authorization_expired"} = MailOAuthFlow.complete(params)
      {second, params} = authorize(workspace, member, "second@example.com")
      assert {:ok, :connected} = MailOAuthFlow.complete(params)

      assert {:ok, %{account_id: second_id}} =
               MailOAuthFlow.get(workspace.id, member.id, second.flow_id)

      refute first_id == second_id
      first_account = Mokaid.Mail.get_account(workspace.id, first_id)
      second_account = Mokaid.Mail.get_account(workspace.id, second_id)
      refute first_account.connection_id == second_account.connection_id
      first_connection = Integrations.get_connection(workspace.id, first_account.connection_id)

      assert Integrations.decrypted_credentials(first_connection)["access_token"] ==
               "access-first@example.com"

      assert all_enqueued(worker: Mokaid.Mail.Workers.SyncWorker)
             |> Enum.map(& &1.args["mail_account_id"])
             |> Enum.sort() == Enum.sort([first_id, second_id])
    end)
  end

  test "reconnection preserves the existing refresh token and account identity", %{
    workspace: workspace,
    member: member
  } do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {first, params} = authorize(workspace, member, "first@example.com", "persistent-refresh")
      assert {:ok, :connected} = MailOAuthFlow.complete(params)
      {:ok, %{account_id: id}} = MailOAuthFlow.get(workspace.id, member.id, first.flow_id)
      {second, params} = authorize(workspace, member, "first@example.com", nil)
      assert {:ok, :connected} = MailOAuthFlow.complete(params)

      assert {:ok, %{account_id: ^id}} =
               MailOAuthFlow.get(workspace.id, member.id, second.flow_id)

      account = Mokaid.Mail.get_account(workspace.id, id)
      connection = Integrations.get_connection(workspace.id, account.connection_id)

      assert Integrations.decrypted_credentials(connection)["refresh_token"] ==
               "persistent-refresh"

      assert length(Integrations.list_connections(workspace.id)) == 1
    end)
  end

  test "missing refresh credentials roll back mailbox connection instead of reporting success", %{
    workspace: workspace,
    member: member
  } do
    {started, params} = authorize(workspace, member, "first@example.com", nil)
    assert {:error, "reconnect_with_consent"} = MailOAuthFlow.complete(params)

    assert {:ok, %{status: "failed", error: "reconnect_with_consent"}} =
             MailOAuthFlow.get(workspace.id, member.id, started.flow_id)

    assert Integrations.list_connections(workspace.id) == []
    assert Mokaid.Mail.list_accounts(workspace.id) == []
  end

  test "cancellation and expired flows cannot create accounts", %{
    workspace: workspace,
    member: member
  } do
    {started, params} = authorize(workspace, member, "first@example.com")

    assert {:error, "authorization_cancelled"} =
             MailOAuthFlow.complete(Map.put(params, "error", "access_denied"))

    assert {:ok, %{status: "failed"}} =
             MailOAuthFlow.get(workspace.id, member.id, started.flow_id)

    {expired, params} = authorize(workspace, member, "first@example.com")

    Repo.get!(MailOAuthFlow, expired.flow_id)
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:error, "authorization_expired"} = MailOAuthFlow.complete(params)

    assert {:ok, %{status: "failed", error: "authorization_expired"}} =
             MailOAuthFlow.get(workspace.id, member.id, expired.flow_id)
  end

  test "desktop cancellation prevents a later Google callback from connecting", %{
    workspace: workspace,
    member: member
  } do
    {started, params} = authorize(workspace, member, "first@example.com")

    assert {:error, :not_found} =
             MailOAuthFlow.cancel(workspace.id, Ecto.UUID.generate(), started.flow_id)

    assert {:ok, %{status: "failed", error: "authorization_cancelled"}} =
             MailOAuthFlow.cancel(workspace.id, member.id, started.flow_id)

    assert {:error, "authorization_expired"} = MailOAuthFlow.complete(params)
    assert Mokaid.Mail.list_accounts(workspace.id) == []
  end

  test "cancellation while Google exchanges credentials prevents persistence", %{
    workspace: workspace,
    member: member
  } do
    {started, params} = authorize(workspace, member, "first@example.com")

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/token" ->
          assert {:ok, %{status: "failed"}} =
                   MailOAuthFlow.cancel(workspace.id, member.id, started.flow_id)

          Req.Test.json(conn, %{access_token: "access", refresh_token: "refresh", scope: @scope})

        "/oauth2/v2/userinfo" ->
          Req.Test.json(conn, %{email: "first@example.com", verified_email: true})
      end
    end)

    assert {:error, "authorization_cancelled"} = MailOAuthFlow.complete(params)
    assert Integrations.list_connections(workspace.id) == []
    assert Mokaid.Mail.list_accounts(workspace.id) == []
  end

  for change <- [:expired, :member_removed, :permission_revoked, :user_suspended] do
    @change change
    test "rejects consent when #{@change} during the provider exchange", %{
      workspace: workspace,
      member: member
    } do
      change = @change
      {started, params} = authorize(workspace, member, "first@example.com")

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/token" ->
            change_authorization(change, started, workspace, member)

            Req.Test.json(conn, %{access_token: "access", refresh_token: "refresh", scope: @scope})

          "/oauth2/v2/userinfo" ->
            Req.Test.json(conn, %{email: "first@example.com", verified_email: true})
        end
      end)

      expected = authorization_error(change)

      assert {:error, ^expected} = MailOAuthFlow.complete(params)

      assert {:ok, %{status: "failed", error: ^expected}} =
               MailOAuthFlow.get(workspace.id, member.id, started.flow_id)

      assert Integrations.list_connections(workspace.id) == []
      assert Mokaid.Mail.list_accounts(workspace.id) == []
    end
  end

  defp authorization_error(:expired), do: "authorization_expired"
  defp authorization_error(_), do: "workspace_access_revoked"

  defp change_authorization(change, started, workspace, member) do
    case change do
      :expired ->
        Repo.get!(MailOAuthFlow, started.flow_id)
        |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1))
        |> Repo.update!()

      :member_removed ->
        member |> Ecto.Changeset.change(status: "removed") |> Repo.update!()

      :permission_revoked ->
        role = Mokaid.Members.get_role_by_name(workspace.id, "Viewer")
        member |> Ecto.Changeset.change(role_id: role.id) |> Repo.update!()

      :user_suspended ->
        Repo.get!(Mokaid.Accounts.User, member.user_id)
        |> Ecto.Changeset.change(status: "suspended")
        |> Repo.update!()
    end
  end
end
