defmodule MokaidWeb.BrowserAuthTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.Auth.{Desktop, Token, WebSession}
  alias Mokaid.Repo
  @origin "http://localhost:5173"
  @password "correct-password-1234"
  @verifier String.duplicate("v", 64)
  @redirect "http://127.0.0.1:55123/callback"

  setup %{conn: conn} do
    {:ok, conn: %{conn | remote_ip: {127, 20, rem(System.unique_integer([:positive]), 254), 1}}}
  end

  defp register(conn) do
    post(put_req_header(conn, "origin", @origin), "/api/auth/register", %{
      email: "browser#{System.unique_integer([:positive])}@example.com",
      password: @password,
      full_name: "Browser User",
      session_transport: "cookie"
    })
  end

  defp browser(conn, "browser:" <> csrf),
    do:
      conn
      |> recycle()
      |> put_req_header("origin", @origin)
      |> put_req_header("x-csrf-token", csrf)

  test "signup cookie, CSRF, desktop approval, PKCE exchange, rotation and browser logout", %{
    conn: conn
  } do
    registered = register(conn)

    %{"token" => marker, "user" => user, "workspace" => workspace} =
      json_response(registered, 201)

    assert String.starts_with?(marker, "browser:")
    assert workspace["id"]
    refute marker =~ "mw_st_"
    assert get_resp_header(registered, "cache-control") == ["no-store"]
    assert [cookie] = get_resp_header(registered, "set-cookie")
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Lax"
    assert {:error, _} = Token.verify(marker)
    assert byte_size(Repo.get_by!(WebSession, user_id: user["id"]).token_hash) == 32
    assert registered |> browser(marker) |> get("/api/me") |> json_response(200)

    request =
      post(conn, "/api/desktop/auth/requests", %{
        code_challenge: Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false),
        state: String.duplicate("s", 43),
        redirect_uri: @redirect
      })
      |> json_response(201)

    id = request["data"]["request_id"]
    path = "/api/desktop/auth/requests/#{id}/approve"

    assert registered
           |> recycle()
           |> put_req_header("origin", @origin)
           |> post(path, %{})
           |> json_response(403)

    assert registered
           |> browser(marker)
           |> put_req_header("origin", "https://evil.example")
           |> post(path, %{})
           |> json_response(403)

    approved = registered |> browser(marker) |> post(path, %{}) |> json_response(200)
    query = URI.decode_query(URI.parse(approved["data"]["redirect_url"]).query)

    grant = %{
      grant_type: "authorization_code",
      code: query["code"],
      code_verifier: @verifier,
      redirect_uri: @redirect
    }

    assert post(conn, "/api/desktop/auth/token", %{
             grant
             | code_verifier: String.duplicate("x", 64)
           })
           |> json_response(400)

    tokens =
      post(conn, "/api/desktop/auth/token", grant) |> json_response(200) |> Map.fetch!("data")

    assert post(conn, "/api/desktop/auth/token", grant) |> json_response(400)

    rotated =
      post(conn, "/api/desktop/auth/token", %{
        grant_type: "refresh_token",
        refresh_token: tokens["refresh_token"]
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert rotated["refresh_token"] != tokens["refresh_token"]
    logged_out = registered |> browser(marker) |> post("/api/auth/logout", %{})
    assert json_response(logged_out, 200)["ok"]
    assert registered |> browser(marker) |> get("/api/me") |> json_response(401)
    # Browser and native sessions have independent lifetimes.
    assert {:ok, _, _} = Desktop.verify_access(rotated["access_token"])
    assert :ok = Desktop.revoke(rotated["refresh_token"])
    assert {:error, _} = Desktop.verify_access(rotated["access_token"])
  end

  test "login fixes session identity and password change revokes browser and native sessions", %{
    conn: conn
  } do
    user = user_fixture(%{password: @password})
    old = Token.sign(user.id)

    {:ok, request} =
      Desktop.create_request(%{
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false),
        "state" => String.duplicate("s", 43),
        "redirect_uri" => @redirect
      })

    {:ok, redirect} = Desktop.approve(request.id, user)
    code = URI.decode_query(URI.parse(redirect).query)["code"]

    {:ok, native} =
      Desktop.exchange(%{
        "code" => code,
        "code_verifier" => @verifier,
        "redirect_uri" => @redirect
      })

    login =
      conn
      |> put_req_header("origin", @origin)
      |> post("/api/auth/login", %{
        email: user.email,
        password: @password,
        session_transport: "cookie"
      })

    marker = json_response(login, 200)["token"]
    socket = %Phoenix.Socket{}
    session = get_session(login)
    assert {:ok, connected} = MokaidWeb.UserSocket.connect(%{}, socket, %{session: session})
    assert String.starts_with?(MokaidWeb.UserSocket.id(connected), "web_session:")
    assert :error = MokaidWeb.UserSocket.connect(%{"token" => marker}, socket, %{})

    changed =
      login
      |> browser(marker)
      |> post("/api/me/password", %{
        current_password: @password,
        password: "changed-password-1234",
        password_confirmation: "changed-password-1234"
      })

    replacement = json_response(changed, 200)["token"]
    assert replacement != marker
    assert {:error, _} = Token.verify(old)
    assert {:error, _} = Desktop.refresh(native.refresh_token)
    assert {:error, _} = Desktop.verify_access(native.access_token)
    assert login |> browser(marker) |> get("/api/me") |> json_response(401)
    assert changed |> browser(replacement) |> get("/api/me") |> json_response(200)
    assert :error = MokaidWeb.UserSocket.connect(%{}, socket, %{session: session})
  end

  test "cookie login requires a trusted Origin and malformed credentials never crash", %{
    conn: conn
  } do
    assert post(conn, "/api/auth/login", %{email: %{}, password: [], session_transport: "cookie"})
           |> json_response(403)

    assert conn
           |> put_req_header("origin", @origin)
           |> post("/api/auth/login", %{email: %{}, password: [], session_transport: "cookie"})
           |> json_response(401)

    assert post(conn, "/api/auth/register", %{email: [], password: %{}, full_name: nil})
           |> json_response(400)

    assert conn
           |> put_req_header("origin", @origin)
           |> post("/api/auth/register", %{
             email: "x@example.com",
             password: "",
             full_name: "Test User",
             session_transport: "cookie"
           })
           |> json_response(422)
  end

  test "failed password attempts are rate limited", %{conn: conn} do
    for _ <- 1..15 do
      assert post(conn, "/api/auth/login", %{email: "absent@example.com", password: @password})
             |> json_response(401)
    end

    response = post(conn, "/api/auth/login", %{email: "absent@example.com", password: @password})
    assert json_response(response, 429)["error"]["code"] == "rate_limited"
    assert get_resp_header(response, "retry-after") == ["60"]
  end
end
