defmodule MokaidWeb.DesktopAuthTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.Auth.Desktop

  @verifier String.duplicate("a", 64)
  @redirect "http://127.0.0.1:51234/callback"

  setup %{conn: conn} do
    # Auth limiter state is intentionally outside the SQL sandbox.
    # Spread across two octets so parallel tests cannot share a Hammer bucket.
    n = System.unique_integer([:positive])
    ip = {127, 10, rem(div(n, 256), 256), rem(n, 256)}
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

  test "dedicated refresh endpoint recovers a committed response and protects credentials", %{
    conn: conn,
    user: user
  } do
    {:ok, request} = Desktop.create_request(attrs())
    {:ok, redirect} = Desktop.approve(request.id, user)
    %{"code" => code} = URI.decode_query(URI.parse(redirect).query)

    {:ok, first} =
      Desktop.exchange(%{
        "code" => code,
        "code_verifier" => @verifier,
        "redirect_uri" => @redirect
      })

    request_id = String.duplicate("r", 43)
    params = %{refresh_token: first.refresh_token, refresh_request_id: request_id}
    rotated = post(conn, "/api/desktop/auth/refresh", params)
    second = json_response(rotated, 200)["data"]
    assert second["refresh_token"] != first.refresh_token
    assert get_resp_header(rotated, "cache-control") == ["no-store"]
    recovered = post(conn, "/api/desktop/auth/refresh", params) |> json_response(200)
    assert recovered["data"]["refresh_token"] == second["refresh_token"]
    assert recovered["data"]["user"]["id"] == user.id
    refute rotated.resp_body =~ request_id
    assert "refresh_request_id" in Application.fetch_env!(:phoenix, :filter_parameters)

    assert post(conn, "/api/desktop/auth/refresh", %{refresh_token: first.refresh_token})
           |> json_response(400)
  end

  test "refresh endpoint applies the token rate limit and never reflects malformed IDs", %{
    conn: conn
  } do
    params = %{refresh_token: "invalid", refresh_request_id: "never-return-this-request-id"}

    for _ <- 1..60 do
      result = post(conn, "/api/desktop/auth/refresh", params)
      assert json_response(result, 400)["error"]["code"] == "invalid_grant"
      refute result.resp_body =~ params.refresh_request_id
    end

    blocked = post(conn, "/api/desktop/auth/refresh", params)
    assert json_response(blocked, 429)["error"]["code"] == "rate_limited"
    assert get_resp_header(blocked, "retry-after") == ["60"]
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
