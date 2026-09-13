defmodule MokaidWeb.DesktopAuthTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.Auth.Desktop

  @verifier String.duplicate("a", 64)
  @redirect "http://127.0.0.1:51234/callback"

  setup %{conn: conn} do
    # Auth limiter state is intentionally outside the SQL sandbox.
    ip = {127, 10, rem(System.unique_integer([:positive]), 254), 1}
    {:ok, conn: %{conn | remote_ip: ip}, user: user_fixture()}
  end

  defp attrs do
    %{
      "code_challenge" => :crypto.hash(:sha256, @verifier) |> Base.url_encode64(padding: false),
      "state" => String.duplicate("s", 43),
      "redirect_uri" => @redirect
    }
  end

  defp login(conn, user),
    do: put_req_header(conn, "authorization", "Bearer " <> Mokaid.Auth.Token.sign(user.id))

  test "complete public request, browser consent, code and refresh HTTP flow", %{
    conn: conn,
    user: user
  } do
    created = post(conn, "/api/desktop/auth/requests", attrs())
    data = json_response(created, 201)["data"]
    assert data["authorization_url"] =~ "/desktop/authorize?request_id=" <> data["request_id"]
    assert get_resp_header(created, "cache-control") == ["no-store"]
    id = data["request_id"]
    shown = conn |> login(user) |> get("/api/desktop/auth/requests/#{id}") |> json_response(200)
    assert shown["data"]["user"]["id"] == user.id
    refute Map.has_key?(shown["data"], "state")

    approved =
      conn
      |> login(user)
      |> post("/api/desktop/auth/requests/#{id}/approve", %{})
      |> json_response(200)

    %{"code" => code, "state" => state} =
      URI.decode_query(URI.parse(approved["data"]["redirect_url"]).query)

    assert state == attrs()["state"]

    result =
      post(conn, "/api/desktop/auth/token", %{
        grant_type: "authorization_code",
        code: code,
        code_verifier: @verifier,
        redirect_uri: @redirect
      })

    tokens = json_response(result, 200)["data"]
    assert tokens["user"]["id"] == user.id
    assert tokens["expires_in"] == 600
    assert get_resp_header(result, "cache-control") == ["no-store"]
    authorized = put_req_header(conn, "authorization", "Bearer " <> tokens["access_token"])
    assert get(authorized, "/api/me") |> json_response(200)

    refreshed =
      post(conn, "/api/desktop/auth/token", %{
        grant_type: "refresh_token",
        refresh_token: tokens["refresh_token"]
      })
      |> json_response(200)

    assert refreshed["data"]["refresh_token"] != tokens["refresh_token"]

    assert post(conn, "/api/desktop/auth/revoke", %{
             refresh_token: refreshed["data"]["refresh_token"]
           })
           |> response(204) == ""

    assert get(authorized, "/api/me") |> json_response(401)
  end

  test "browser request inspection and approval require bearer auth", %{conn: conn} do
    {:ok, request} = Desktop.create_request(attrs())
    assert get(conn, "/api/desktop/auth/requests/#{request.id}") |> json_response(401)

    assert post(conn, "/api/desktop/auth/requests/#{request.id}/approve", %{})
           |> json_response(401)
  end

  test "invalid input is bounded and errors do not reflect secrets", %{conn: conn} do
    secret = "never-return-this-secret"

    response =
      post(conn, "/api/desktop/auth/token", %{grant_type: "refresh_token", refresh_token: secret})

    assert json_response(response, 400)["error"]["code"] == "invalid_grant"
    refute response.resp_body =~ secret

    assert post(conn, "/api/desktop/auth/requests", %{state: %{nested: "bad"}})
           |> json_response(400)

    assert post(conn, "/api/desktop/auth/revoke", %{refresh_token: secret}) |> response(204) == ""
  end

  test "creation is rate limited with retry guidance", %{conn: conn} do
    for _ <- 1..15, do: assert(post(conn, "/api/desktop/auth/requests", attrs()) |> response(201))
    blocked = post(conn, "/api/desktop/auth/requests", attrs())
    assert json_response(blocked, 429)["error"]["code"] == "rate_limited"
    assert get_resp_header(blocked, "retry-after") == ["60"]
  end
end
