defmodule MokaidWeb.MailOAuthControllerTest do
  use MokaidWeb.ConnCase, async: false
  alias Mokaid.Auth.{Desktop, Token}

  setup do
    previous = Application.get_env(:mokaid, :google_oauth)
    previous_rollout = Application.get_env(:mokaid, :desktop_only_business)

    Application.put_env(:mokaid, :google_oauth,
      client_id: "test-client",
      client_secret: "test-secret",
      desktop_redirect_uri: "https://mokaid.com/api/mail/oauth/google/callback"
    )

    Application.put_env(:mokaid, :desktop_only_business, true)

    on_exit(fn ->
      Application.put_env(:mokaid, :google_oauth, previous)
      Application.put_env(:mokaid, :desktop_only_business, previous_rollout)
    end)

    {workspace, user} = workspace_fixture()
    %{workspace: workspace, user: user}
  end

  defp native_token(user) do
    verifier = String.duplicate("v", 64)
    redirect = "http://127.0.0.1:54321/callback"

    {:ok, request} =
      Desktop.create_request(%{
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        "state" => String.duplicate("s", 43),
        "redirect_uri" => redirect
      })

    {:ok, callback} = Desktop.approve(request.id, user)
    %{"code" => code} = URI.decode_query(URI.parse(callback).query)

    {:ok, tokens} =
      Desktop.exchange(%{"code" => code, "code_verifier" => verifier, "redirect_uri" => redirect})

    tokens.access_token
  end

  defp authenticate(conn, token, workspace) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-workspace-id", workspace.id)
  end

  test "native mailbox flow can start and poll without a browser session", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    token = native_token(user)

    response =
      conn
      |> authenticate(token, workspace)
      |> post("/api/mail/oauth/google/start", %{})
      |> json_response(200)

    id = response["data"]["flow_id"]
    authorize = URI.decode_query(URI.parse(response["data"]["authorize_url"]).query)
    assert authorize["redirect_uri"] == "https://mokaid.com/api/mail/oauth/google/callback"

    assert conn
           |> authenticate(token, workspace)
           |> get("/api/mail/oauth/" <> id)
           |> json_response(200) == %{
             "data" => %{"status" => "pending", "account_id" => nil, "error" => nil}
           }

    assert conn
           |> authenticate(token, workspace)
           |> get("/api/mail/oauth/not-a-uuid")
           |> json_response(404)
  end

  test "browser sessions cannot initiate desktop mail consent", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    response =
      conn
      |> authenticate(Token.sign(user.id), workspace)
      |> post("/api/mail/oauth/google/start", %{})
      |> json_response(403)

    assert response["error"]["code"] == "desktop_required"
  end

  test "public provider return accepts an ordinary browser and reveals no codes", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "text/html")
      |> get("/api/mail/oauth/google/callback", %{state: "invalid", code: "secret-code"})

    assert html_response(conn, 400) =~ "Return to Mokaid Desktop"
    refute conn.resp_body =~ "secret-code"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
  end

  test "native cancellation persists a failed flow", %{
    conn: conn,
    workspace: workspace,
    user: user
  } do
    token = native_token(user)

    response =
      conn
      |> authenticate(token, workspace)
      |> post("/api/mail/oauth/google/start", %{})
      |> json_response(200)

    id = response["data"]["flow_id"]

    cancelled =
      conn
      |> authenticate(token, workspace)
      |> delete("/api/mail/oauth/" <> id)
      |> json_response(200)

    assert cancelled["data"]["status"] == "failed"
    assert cancelled["data"]["error"] == "authorization_cancelled"
  end
end
