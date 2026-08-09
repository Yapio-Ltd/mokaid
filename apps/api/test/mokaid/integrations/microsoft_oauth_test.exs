defmodule Mokaid.Integrations.MicrosoftOAuthTest do
  use ExUnit.Case, async: false

  alias Mokaid.Integrations.MicrosoftOAuth

  setup do
    original = Application.get_env(:mokaid, :microsoft_oauth)

    on_exit(fn ->
      if original do
        Application.put_env(:mokaid, :microsoft_oauth, original)
      else
        Application.delete_env(:mokaid, :microsoft_oauth)
      end
    end)

    :ok
  end

  test "unconfigured environment returns a clear error" do
    Application.put_env(:mokaid, :microsoft_oauth, client_id: nil, client_secret: nil)
    refute MicrosoftOAuth.configured?()

    assert {:error, :oauth_not_configured} =
             MicrosoftOAuth.authorize_url(
               "ws",
               "member",
               "https://mokaid.com/oauth/microsoft/callback"
             )
  end

  test "authorize_url builds the common-tenant consent URL" do
    Application.put_env(:mokaid, :microsoft_oauth,
      client_id: "client-123",
      client_secret: "secret",
      tenant: "common",
      redirect_uris: ["https://mokaid.com/oauth/microsoft/callback"]
    )

    assert {:ok, url} =
             MicrosoftOAuth.authorize_url(
               "ws-1",
               "member-1",
               "https://mokaid.com/oauth/microsoft/callback"
             )

    assert url =~ "login.microsoftonline.com/common/oauth2/v2.0/authorize"
    assert url =~ "client_id=client-123"
    assert url =~ "offline_access"
    assert url =~ "Mail.Read"
    assert url =~ "state="
  end

  test "rejects redirect URIs outside the allowlist" do
    Application.put_env(:mokaid, :microsoft_oauth,
      client_id: "client-123",
      client_secret: "secret",
      redirect_uris: ["https://mokaid.com/oauth/microsoft/callback"]
    )

    assert {:error, :invalid_redirect_uri} =
             MicrosoftOAuth.authorize_url("ws", "member", "https://evil.example.com/cb")
  end

  test "outlook is the only microsoft provider key" do
    assert MicrosoftOAuth.microsoft_provider?("outlook")
    refute MicrosoftOAuth.microsoft_provider?("gmail")
    assert MicrosoftOAuth.provider_key() == "outlook"
  end
end
