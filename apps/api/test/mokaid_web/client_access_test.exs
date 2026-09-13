defmodule MokaidWeb.ClientAccessTest do
  # The rollout config is process-global; keep this suite synchronous.
  use MokaidWeb.ConnCase, async: false
  alias Mokaid.Auth.{ClientPolicy, Desktop, Token}
  alias MokaidWeb.{NotificationChannel, UserSocket, WorkspaceChannel}

  @redirect "http://127.0.0.1:54321/callback"
  @verifier String.duplicate("v", 64)

  setup do
    previous = Application.fetch_env(:mokaid, :desktop_only_business)
    Application.put_env(:mokaid, :desktop_only_business, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mokaid, :desktop_only_business, value)
        :error -> Application.delete_env(:mokaid, :desktop_only_business)
      end
    end)

    {workspace, user} = workspace_fixture()
    {:ok, user: user, workspace: workspace, browser: Token.sign(user.id)}
  end

  defp authenticated(conn, token, workspace_id \\ nil) do
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    if workspace_id, do: put_req_header(conn, "x-workspace-id", workspace_id), else: conn
  end

  defp attrs do
    %{
      "code_challenge" => :crypto.hash(:sha256, @verifier) |> Base.url_encode64(padding: false),
      "state" => String.duplicate("s", 43),
      "redirect_uri" => @redirect
    }
  end

  defp native_tokens(user) do
    {:ok, request} = Desktop.create_request(attrs())
    {:ok, callback} = Desktop.approve(request.id, user)
    %{"code" => code} = URI.decode_query(URI.parse(callback).query)

    {:ok, tokens} =
      Desktop.exchange(%{
        "code" => code,
        "code_verifier" => @verifier,
        "redirect_uri" => @redirect
      })

    tokens
  end

  test "rollout OFF preserves legacy HTTP and Channels", %{
    conn: conn,
    browser: browser,
    workspace: workspace
  } do
    Application.delete_env(:mokaid, :desktop_only_business)
    refute ClientPolicy.enabled?()
    assert conn |> authenticated(browser, workspace.id) |> get("/api/tasks") |> json_response(200)
    assert {:ok, _} = UserSocket.connect(%{"token" => browser}, %Phoenix.Socket{}, %{})
  end

  test "browser account billing and workspace selection remain authorized", %{
    conn: conn,
    browser: browser,
    workspace: workspace,
    user: user
  } do
    me = conn |> authenticated(browser) |> get("/api/me") |> json_response(200)
    assert me["user"]["id"] == user.id
    assert me["client_policy"] == %{"desktop_only_business" => true}
    assert Enum.any?(me["workspaces"], &(&1["id"] == workspace.id))

    for path <- [
          "/api/workspaces",
          "/api/workspaces/#{workspace.id}",
          "/api/members",
          "/api/billing/overview",
          "/api/billing/invoices",
          "/api/billing/plans",
          "/api/billing/credit-packs",
          "/api/billing/config"
        ] do
      assert conn |> authenticated(browser, workspace.id) |> get(path) |> json_response(200)
    end

    updated =
      conn
      |> authenticated(browser)
      |> patch("/api/me", %{full_name: "Account-only profile"})
      |> json_response(200)

    assert updated["user"]["full_name"] == "Account-only profile"
  end

  test "browser business reads are denied without trusting declared desktop headers", %{
    conn: conn,
    browser: browser,
    workspace: workspace
  } do
    for path <- [
          "/api/tasks",
          "/api/projects",
          "/api/agents",
          "/api/assets-3d",
          "/api/agent-chats",
          "/api/knowledge",
          "/api/knowledge-graph",
          "/api/drive",
          "/api/drive-trash",
          "/api/calendar/events",
          "/api/integrations",
          "/api/mcp",
          "/api/mail/messages",
          "/api/analytics/overview",
          "/api/notifications",
          "/api/search?q=private",
          "/api/admin/users",
          "/api/leave-requests"
        ] do
      response =
        conn
        |> authenticated(browser, workspace.id)
        |> put_req_header("user-agent", "MokaidDesktop/99.0")
        |> put_req_header("x-mokaid-client", "desktop")
        |> put_req_header("x-mokaid-authorization", "Bearer " <> browser)
        |> get(path)

      assert json_response(response, 403)["error"]["code"] == "desktop_required", path
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end
  end

  test "browser cannot mutate workspaces memberships or business data", %{
    conn: conn,
    browser: browser,
    workspace: workspace,
    user: user
  } do
    member = Mokaid.Members.get_member_for_user(workspace.id, user.id)

    for {method, path, body} <- [
          {:post, "/api/workspaces", %{name: "Must not be created"}},
          {:patch, "/api/workspaces/#{workspace.id}", %{name: "Must not change"}},
          {:delete, "/api/workspaces/#{workspace.id}", %{}},
          {:post, "/api/members/invite", %{email: "no-invitation@example.invalid"}},
          {:patch, "/api/members/#{member.id}", %{status: "removed"}},
          {:post, "/api/tasks", %{title: "Must not be created"}},
          {:post, "/api/integrations/github/oauth/start", %{}}
        ] do
      response =
        dispatch(authenticated(conn, browser, workspace.id), @endpoint, method, path, body)

      assert json_response(response, 403)["error"]["code"] == "desktop_required"
    end

    assert Mokaid.Workspaces.get_workspace(workspace.id).name == workspace.name
    assert Mokaid.Members.get_member_for_user(workspace.id, user.id)
  end

  test "valid native sessions can create and read real workspace tasks", %{
    conn: conn,
    user: user,
    workspace: workspace
  } do
    tokens = native_tokens(user)
    native = authenticated(conn, tokens.access_token, workspace.id)

    created =
      native |> post("/api/tasks", %{title: "Native-only actual task"}) |> json_response(201)

    id = created["data"]["id"]
    assert Mokaid.Tasks.get_task(workspace.id, id).title == "Native-only actual task"
    assert native |> get("/api/tasks/#{id}") |> json_response(200)
    assert native |> get("/api/me") |> json_response(200)
  end

  test "both browser billing and native business preserve horizontal isolation", %{
    conn: conn,
    browser: browser,
    user: user,
    workspace: workspace
  } do
    {foreign, _} = workspace_fixture()
    tokens = native_tokens(user)

    for path <- ["/api/billing/overview", "/api/billing/invoices", "/api/members"] do
      denied = conn |> authenticated(browser, foreign.id) |> get(path) |> json_response(403)
      assert denied["error"]["code"] == "forbidden"
    end

    assert conn
           |> authenticated(browser, workspace.id)
           |> get("/api/workspaces/#{foreign.id}")
           |> json_response(403)

    assert conn
           |> authenticated(tokens.access_token, foreign.id)
           |> get("/api/tasks")
           |> json_response(403)

    own =
      conn
      |> authenticated(tokens.access_token, workspace.id)
      |> get("/api/tasks")
      |> json_response(200)

    assert own["data"] == []
  end

  test "web billing does not bypass the existing billing role permission", %{
    conn: conn,
    browser: browser,
    user: user,
    workspace: workspace
  } do
    member = Mokaid.Members.get_member_for_user(workspace.id, user.id)
    role = Mokaid.Members.get_role_by_name(workspace.id, "Viewer")
    member |> Ecto.Changeset.change(role_id: role.id) |> Repo.update!()

    assert conn
           |> authenticated(browser, workspace.id)
           |> get("/api/billing/overview")
           |> json_response(403)
  end

  test "operator role alone does not grant browser business or desktop workspace membership", %{
    conn: conn,
    user: user
  } do
    user = user |> Ecto.Changeset.change(is_platform_admin: true) |> Repo.update!()
    tokens = native_tokens(user)
    browser = authenticated(conn, Token.sign(user.id))

    assert get(browser, "/api/admin/users") |> json_response(403) |> get_in(["error", "code"]) ==
             "desktop_required"

    assert conn
           |> authenticated(tokens.access_token)
           |> get("/api/admin/users")
           |> json_response(200)

    {foreign, _} = workspace_fixture()

    assert conn
           |> authenticated(tokens.access_token, foreign.id)
           |> get("/api/tasks")
           |> json_response(403)

    user |> Ecto.Changeset.change(is_platform_admin: false) |> Repo.update!()

    denied =
      conn |> authenticated(tokens.access_token) |> get("/api/admin/users") |> json_response(403)

    assert denied["error"]["code"] == "forbidden"
  end

  test "forged desktop prefix and revoked native tokens do not cross the gate", %{
    conn: conn,
    browser: browser,
    user: user,
    workspace: workspace
  } do
    assert conn
           |> authenticated("md_at_" <> browser, workspace.id)
           |> get("/api/tasks")
           |> json_response(401)

    tokens = native_tokens(user)
    :ok = Desktop.revoke(tokens.refresh_token)

    assert conn
           |> authenticated(tokens.access_token, workspace.id)
           |> get("/api/tasks")
           |> json_response(401)

    assert conn |> authenticated(browser) |> post("/api/worker/usage", %{}) |> json_response(401)
  end

  test "browser desktop consent and validated OAuth callback paths remain reachable", %{
    conn: conn,
    browser: browser,
    workspace: workspace
  } do
    previous = Application.fetch_env!(:mokaid, :github_oauth)
    on_exit(fn -> Application.put_env(:mokaid, :github_oauth, previous) end)
    callback_uri = "http://127.0.0.1:5178/oauth/github/callback"

    Application.put_env(:mokaid, :github_oauth,
      client_id: "public-test-fixture",
      client_secret: "public-test-fixture",
      redirect_uris: [callback_uri]
    )

    {:ok, request} = Desktop.create_request(attrs())

    assert conn
           |> authenticated(browser)
           |> get("/api/desktop/auth/requests/#{request.id}")
           |> json_response(200)

    approved =
      conn
      |> authenticated(browser)
      |> post("/api/desktop/auth/requests/#{request.id}/approve", %{})
      |> json_response(200)

    assert URI.parse(approved["data"]["redirect_url"]).host == "127.0.0.1"

    callback =
      conn
      |> authenticated(browser, workspace.id)
      |> post("/api/integrations/github/oauth/callback", %{
        code: "invalid-code",
        state: "invalid-state",
        redirect_uri: callback_uri
      })

    assert json_response(callback, 422)["error"]["code"] == "invalid_state"
  end

  test "Channels reject browser tokens even in native headers but preserve native topic scopes",
       %{browser: browser, user: user, workspace: workspace} do
    assert :error = UserSocket.connect(%{"token" => browser}, %Phoenix.Socket{}, %{})

    assert :error =
             UserSocket.connect(%{}, %Phoenix.Socket{}, %{
               x_headers: [{"x-mokaid-authorization", "Bearer " <> browser}]
             })

    tokens = native_tokens(user)

    assert {:ok, socket} =
             UserSocket.connect(%{}, %Phoenix.Socket{}, %{
               x_headers: [{"x-mokaid-authorization", "Bearer " <> tokens.access_token}]
             })

    assert {:ok, _} = NotificationChannel.join("notifications:" <> user.id, %{}, socket)
    {foreign, outsider} = workspace_fixture()

    assert {:error, %{reason: "forbidden"}} =
             NotificationChannel.join("notifications:" <> outsider.id, %{}, socket)

    assert {:error, %{reason: "forbidden"}} =
             WorkspaceChannel.join("workspace:" <> foreign.id, %{}, socket)

    assert {:ok, _} = WorkspaceChannel.join("workspace:" <> workspace.id, %{}, socket)
    assert_receive :after_join
  end

  test "existing browser transport stops on input output and idle check after activation", %{
    browser: browser
  } do
    Application.put_env(:mokaid, :desktop_only_business, false)
    {:ok, socket} = UserSocket.connect(%{"token" => browser}, %Phoenix.Socket{}, %{})
    Application.put_env(:mokaid, :desktop_only_business, true)
    state = {%{}, socket}
    assert {:stop, :normal, ^state} = UserSocket.handle_in({"ignored", []}, state)

    assert {:stop, :normal, ^state} =
             UserSocket.handle_info({:socket_push, :text, "private"}, state)

    assert {:stop, :normal, ^state} = UserSocket.handle_info(:auth_session_check, state)
  end

  test "new controller actions are denied by default and desktop metadata must be complete" do
    refute ClientPolicy.browser_action?(MokaidWeb.BillingController, :unreviewed_export)
    refute ClientPolicy.http_allowed?(%{}, MokaidWeb.TaskController, :index)
    refute ClientPolicy.channels_allowed?(%{client: "desktop"})
    refute ClientPolicy.channels_allowed?(%{desktop_session_id: "unverified-shape"})
    assert ClientPolicy.browser_action?(MokaidWeb.BillingController, :credits_checkout)
    refute ClientPolicy.browser_action?(MokaidWeb.WorkspaceController, :create)
    refute ClientPolicy.browser_action?(MokaidWeb.MemberController, :update)
  end

  test "the compiled router exposes exactly the reviewed browser method/path allowlist" do
    actual =
      Phoenix.Router.routes(MokaidWeb.Router)
      |> Enum.filter(&ClientPolicy.browser_action?(&1.plug, &1.plug_opts))
      |> Enum.map(fn route ->
        method = String.upcase(to_string(route.verb))
        info = Phoenix.Router.route_info(MokaidWeb.Router, method, route.path, "localhost")
        assert :authenticated in info.pipe_through
        method <> " " <> route.path
      end)
      |> Enum.sort()

    expected = [
      "GET /api/me",
      "PATCH /api/me",
      "POST /api/me/password",
      "GET /api/me/avatar",
      "POST /api/me/avatar",
      "DELETE /api/me/avatar",
      "GET /api/workspaces",
      "GET /api/workspaces/:id",
      "GET /api/workspaces/:id/logo",
      "GET /api/members",
      "GET /api/desktop/auth/requests/:id",
      "POST /api/desktop/auth/requests/:id/approve",
      "GET /api/billing/overview",
      "GET /api/billing/invoices",
      "GET /api/billing/plans",
      "GET /api/billing/credit-packs",
      "GET /api/billing/config",
      "POST /api/billing/change-plan",
      "POST /api/billing/checkout",
      "POST /api/billing/credits/checkout",
      "POST /api/billing/auto-recharge",
      "POST /api/billing/portal",
      "POST /api/integrations/google/oauth/callback",
      "POST /api/integrations/github/oauth/callback",
      "POST /api/integrations/linear/oauth/callback",
      "POST /api/integrations/slack/oauth/callback",
      "POST /api/integrations/notion/oauth/callback",
      "POST /api/integrations/microsoft/oauth/callback",
      "POST /api/mcp/figma/oauth/callback"
    ]

    assert actual == Enum.sort(expected)
  end
end
