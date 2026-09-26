defmodule Mokaid.MailDisconnectTest do
  use Mokaid.DataCase, async: false
  alias Mokaid.{Integrations, Mail, Repo, Vault}
  alias Mokaid.Integrations.{IntegrationConnection, IntegrationProvider, TokenRefresher}
  alias Mokaid.Mail.Account

  defp context do
    {workspace, owner} = workspace_fixture()
    {workspace, owner_member(workspace, owner)}
  end

  defp connection(workspace, member, key, email) do
    provider =
      Repo.insert!(
        %IntegrationProvider{key: key, name: key, category: "communication", enabled: true},
        on_conflict: {:replace, [:name]},
        conflict_target: :key,
        returning: true
      )

    Repo.insert!(%IntegrationConnection{
      workspace_id: workspace.id,
      provider_id: provider.id,
      connected_by_member_id: member.id,
      connected_account: email,
      status: "connected",
      encrypted_credentials:
        Vault.encrypt(%{
          "access_token" => "access",
          "refresh_token" => "refresh",
          "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60))
        })
    })
  end

  defp mailbox(workspace, member, provider, email, connection) do
    Repo.insert!(%Account{
      workspace_id: workspace.id,
      member_id: member.id,
      provider: provider,
      email_address: email,
      connection_id: connection.id
    })
  end

  test "disconnect clears only the exact Gmail or Microsoft integration" do
    for {provider, key} <- [{"gmail", "gmail"}, {"microsoft", "outlook"}] do
      {workspace, member} = context()
      own = connection(workspace, member, key, "first@example.com")
      other = connection(workspace, member, key, "other@example.com")
      drive = connection(workspace, member, "google_drive", "first@example.com")
      account = mailbox(workspace, member, provider, "first@example.com", own)
      remaining = mailbox(workspace, member, provider, "other@example.com", other)
      assert {:ok, _} = Mail.delete_account(account)
      assert is_nil(Mail.get_account(workspace.id, account.id))
      disconnected = Integrations.get_connection(workspace.id, own.id)
      assert disconnected.status == "disconnected"
      assert is_nil(disconnected.encrypted_credentials)
      assert Integrations.decrypted_credentials(disconnected) == nil
      assert Integrations.get_connection(workspace.id, other.id).status == "connected"

      assert Integrations.get_connection(workspace.id, drive.id).encrypted_credentials ==
               drive.encrypted_credentials

      assert Mail.get_account(workspace.id, remaining.id)
    end
  end

  test "legacy shared or mismatched references never clear another mailbox identity" do
    {workspace, member} = context()
    own = connection(workspace, member, "gmail", "first@example.com")
    first = mailbox(workspace, member, "gmail", "first@example.com", own)
    legacy = mailbox(workspace, member, "gmail", "legacy@example.com", own)
    assert {:ok, _} = Mail.delete_account(first)

    assert Integrations.get_connection(workspace.id, own.id).encrypted_credentials ==
             own.encrypted_credentials

    assert {:ok, _} = Mail.delete_account(legacy)

    assert Integrations.get_connection(workspace.id, own.id).encrypted_credentials ==
             own.encrypted_credentials
  end

  test "foreign workspace and mismatched provider connections are untouched" do
    {workspace, member} = context()
    {other_workspace, other_member} = context()
    foreign = connection(other_workspace, other_member, "gmail", "first@example.com")
    account = mailbox(workspace, member, "gmail", "first@example.com", foreign)
    assert {:ok, _} = Mail.delete_account(account)

    assert Integrations.get_connection(other_workspace.id, foreign.id).encrypted_credentials ==
             foreign.encrypted_credentials

    drive = connection(workspace, member, "google_drive", "first@example.com")
    account = mailbox(workspace, member, "gmail", "first@example.com", drive)
    assert {:ok, _} = Mail.delete_account(account)

    assert Integrations.get_connection(workspace.id, drive.id).encrypted_credentials ==
             drive.encrypted_credentials
  end

  test "a refresh finishing after disconnect cannot restore credentials" do
    {workspace, member} = context()
    own = connection(workspace, member, "gmail", "first@example.com")
    account = mailbox(workspace, member, "gmail", "first@example.com", own)
    previous = Application.get_env(:mokaid, :google_oauth)
    previous_http = Application.get_env(:mokaid, :google_oauth_http_options)
    Application.put_env(:mokaid, :google_oauth, client_id: "test", client_secret: "test")
    Application.put_env(:mokaid, :google_oauth_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :google_oauth, previous)
      Application.put_env(:mokaid, :google_oauth_http_options, previous_http)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert {:ok, _} = Mail.delete_account(account)
      Req.Test.json(conn, %{access_token: "refreshed", refresh_token: "rotated"})
    end)

    assert {:error, :credentials_changed} = TokenRefresher.fresh_credentials(own)
    disconnected = Integrations.get_connection(workspace.id, own.id)
    assert disconnected.status == "disconnected"
    assert is_nil(disconnected.encrypted_credentials)
  end

  test "a delayed refresh preserves newer reconnect credentials without disabling the mailbox" do
    {workspace, member} = context()
    own = connection(workspace, member, "gmail", "first@example.com")
    previous = Application.get_env(:mokaid, :google_oauth)
    previous_http = Application.get_env(:mokaid, :google_oauth_http_options)
    Application.put_env(:mokaid, :google_oauth, client_id: "test", client_secret: "test")
    Application.put_env(:mokaid, :google_oauth_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :google_oauth, previous)
      Application.put_env(:mokaid, :google_oauth_http_options, previous_http)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      assert {:ok, _} =
               Integrations.store_credentials(own, %{
                 "access_token" => "newer-access",
                 "refresh_token" => "newer-refresh",
                 "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
               })

      Req.Test.json(conn, %{access_token: "stale-refresh", refresh_token: "stale-refresh-token"})
    end)

    assert {:ok, %{"access_token" => "newer-access"}} = TokenRefresher.fresh_credentials(own)
    current = Integrations.get_connection(workspace.id, own.id)
    assert Integrations.decrypted_credentials(current)["refresh_token"] == "newer-refresh"
  end
end
