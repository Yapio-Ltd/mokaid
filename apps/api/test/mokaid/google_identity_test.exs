defmodule Mokaid.Auth.GoogleIdentityTest do
  use ExUnit.Case, async: false
  alias Mokaid.Auth.Google
  @redirect "http://localhost:5173/auth/google/callback"
  @other "https://mokaid.com/auth/google/callback"
  @verifier String.duplicate("x", 64)
  @challenge Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false)

  setup do
    previous = Application.get_env(:mokaid, :google_oauth)

    Application.put_env(:mokaid, :google_oauth,
      client_id: "test-client",
      client_secret: "test-secret"
    )

    previous_http = Application.get_env(:mokaid, :google_identity_http_options, [])
    Application.put_env(:mokaid, :google_identity_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :google_oauth, previous)
      Application.put_env(:mokaid, :google_identity_http_options, previous_http)
    end)
  end

  test "identity authorization requires S256 and produces unique browser-bound state" do
    assert {:error, :invalid_state} = Google.authorize_url(@redirect)

    assert {:error, :invalid_state} =
             Google.authorize_url(@redirect, code_challenge: @challenge, intent: %{})

    assert {:ok, first} = Google.authorize_url(@redirect, code_challenge: @challenge)
    assert {:ok, second} = Google.authorize_url(@redirect, code_challenge: @challenge)
    query = URI.decode_query(URI.parse(first).query)
    assert query["code_challenge_method"] == "S256"
    assert query["code_challenge"] == @challenge
    refute query["state"] == URI.decode_query(URI.parse(second).query)["state"]

    assert {:error, :invalid_state} =
             Google.exchange_code("test-code", query["state"], @other, @verifier)

    assert {:error, :invalid_credentials} =
             Google.exchange_code(
               "test-code",
               query["state"],
               @redirect,
               String.duplicate("y", 64)
             )

    assert {:error, :invalid_state} = Google.exchange_code(%{}, %{}, @redirect, @verifier)
  end

  test "provider exchange sends the PKCE verifier and only accepts a verified email" do
    for verified <- [true, false] do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/token" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            form = URI.decode_query(body)
            assert form["code_verifier"] == @verifier
            assert form["redirect_uri"] == @redirect
            Req.Test.json(conn, %{access_token: "provider-access"})

          "/oauth2/v2/userinfo" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer provider-access"]

            Req.Test.json(conn, %{
              id: "google-user",
              email: "User@example.com",
              name: "Google User",
              verified_email: verified
            })
        end
      end)

      {:ok, url} = Google.authorize_url(@redirect, code_challenge: @challenge)
      state = URI.decode_query(URI.parse(url).query)["state"]

      if verified do
        assert {:ok, %{sub: "google-user", email: "user@example.com", email_verified: true}} =
                 Google.exchange_code("code", state, @redirect, @verifier)
      else
        assert {:error, :invalid_credentials} =
                 Google.exchange_code("code", state, @redirect, @verifier)
      end
    end
  end
end
