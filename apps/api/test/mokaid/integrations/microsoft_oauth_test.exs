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

    scopes =
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("scope")
      |> String.split()

    assert "Mail.ReadWrite" in scopes
    assert "Mail.Send" in scopes
    refute "Mail.Read" in scopes
    assert url =~ "state="
  end

  test "refresh retains the original scope instead of silently requesting new permissions" do
    Application.put_env(:mokaid, :microsoft_oauth,
      client_id: "client",
      client_secret: "secret",
      http_options: [plug: {Req.Test, __MODULE__}]
    )

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert params["grant_type"] == "refresh_token"
      refute Map.has_key?(params, "scope")
      Req.Test.json(conn, %{access_token: "fresh", expires_in: 3600, scope: "Mail.Read"})
    end)

    assert {:ok, credentials} = MicrosoftOAuth.refresh_tokens("existing-refresh")
    assert credentials["scope"] == "Mail.Read"
    assert credentials["refresh_token"] == "existing-refresh"
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

  test "omitted refresh scope preserves stored scope and provider errors cannot leak tokens" do
    Application.put_env(:mokaid, :microsoft_oauth,
      client_id: "client",
      client_secret: "secret",
      http_options: [plug: {Req.Test, __MODULE__}]
    )

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{access_token: "fresh", expires_in: 3600})
    end)

    assert {:ok, credentials} = MicrosoftOAuth.refresh_tokens("existing-refresh")
    refute Map.has_key?(credentials, "scope")
    assert Map.merge(%{"scope" => "Mail.Read"}, credentials)["scope"] == "Mail.Read"

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: "secret-token-echo"})
    end)

    assert {:error, {:token_refresh_failed, 400, :provider_error}} =
             MicrosoftOAuth.refresh_tokens("private-refresh")
  end

  test "outlook is the only microsoft provider key" do
    assert MicrosoftOAuth.microsoft_provider?("outlook")
    refute MicrosoftOAuth.microsoft_provider?("gmail")
    assert MicrosoftOAuth.provider_key() == "outlook"
  end
end
