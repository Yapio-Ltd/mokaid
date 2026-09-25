defmodule Mokaid.Integrations.GoogleMailOAuthTest do
  use ExUnit.Case, async: false
  alias Mokaid.Integrations.GoogleOAuth

  @redirect "http://localhost:5173/oauth/google/callback"
  @desktop "https://mokaid.com/api/mail/oauth/google/callback"
  @gmail_scope "https://www.googleapis.com/auth/gmail.modify"

  setup do
    previous = Application.get_env(:mokaid, :google_oauth)
    previous_http = Application.get_env(:mokaid, :google_oauth_http_options, [])

    Application.put_env(:mokaid, :google_oauth,
      client_id: "test-client",
      client_secret: "test-secret",
      redirect_uris: [@redirect],
      desktop_redirect_uri: @desktop
    )

    Application.put_env(:mokaid, :google_oauth_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :google_oauth, previous)
      Application.put_env(:mokaid, :google_oauth_http_options, previous_http)
    end)
  end

  test "Gmail asks only for mail and verified identity with unique encrypted S256 state" do
    {:ok, first} = GoogleOAuth.authorize_url("workspace", "member", @redirect, "gmail")
    {:ok, second} = GoogleOAuth.authorize_url("workspace", "member", @redirect, "gmail")
    query = URI.decode_query(URI.parse(first).query)
    assert String.split(query["scope"]) == ["openid", "email", @gmail_scope]
    assert query["include_granted_scopes"] == "false"
    assert query["code_challenge_method"] == "S256"
    assert query["prompt"] == "consent select_account"
    refute query["state"] == URI.decode_query(URI.parse(second).query)["state"]
    assert {:ok, data} = GoogleOAuth.verify_state(query["state"], @redirect)

    assert query["code_challenge"] ==
             Base.url_encode64(:crypto.hash(:sha256, data.code_verifier), padding: false)

    refute query["state"] =~ data.code_verifier
    assert {:error, :invalid_state} = GoogleOAuth.verify_state(query["state"], @desktop)

    assert {:error, :invalid_state} =
             GoogleOAuth.exchange_code(
               "code",
               query["state"],
               @redirect,
               {"workspace", "another-member"}
             )

    assert {:error, :invalid_state} = GoogleOAuth.exchange_code("code", query["state"], @redirect)
    assert {:error, :invalid_state} = GoogleOAuth.exchange_code(%{}, %{}, @redirect)
  end

  test "provider exchange sends the bound verifier and checks consent and verified email" do
    for {scope, verified, expected} <- [
          {@gmail_scope, true, :ok},
          {"openid email", true, :missing_required_scopes},
          {@gmail_scope, false, :unverified_account}
        ] do
      {:ok, url} = GoogleOAuth.authorize_url("workspace", "member", @redirect, "gmail")
      state = URI.decode_query(URI.parse(url).query)["state"]
      {:ok, data} = GoogleOAuth.verify_state(state, @redirect)

      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/token" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            assert URI.decode_query(body)["code_verifier"] == data.code_verifier
            assert URI.decode_query(body)["redirect_uri"] == @redirect
            Req.Test.json(conn, %{access_token: "access", refresh_token: "refresh", scope: scope})

          "/oauth2/v2/userinfo" ->
            Req.Test.json(conn, %{email: "User@example.com", verified_email: verified})
        end
      end)

      result = GoogleOAuth.exchange_code("code", state, @redirect, {"workspace", "member"})

      if expected == :ok do
        assert {:ok, %{account: "user@example.com", credentials: %{"refresh_token" => "refresh"}}} =
                 result
      else
        assert {:error, ^expected} = result
      end
    end
  end

  test "refresh retains the refresh token when Google does not rotate it and sanitizes errors" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{access_token: "fresh"}) end)

    assert {:ok, %{"access_token" => "fresh", "refresh_token" => "old-refresh"} = credentials} =
             GoogleOAuth.refresh_tokens("old-refresh")

    refute Map.has_key?(credentials, "scope")

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 400, ~s({"error":"sensitive provider details"}))
    end)

    assert {:error, {:token_refresh_failed, 400, :provider_error}} =
             GoogleOAuth.refresh_tokens("old-refresh")
  end
end
