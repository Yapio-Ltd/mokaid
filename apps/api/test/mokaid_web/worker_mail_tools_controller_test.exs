defmodule MokaidWeb.WorkerMailToolsControllerTest do
  use MokaidWeb.ConnCase, async: false
  alias Mokaid.Mail.{Account, AgentAccess, Message}

  setup do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)
    access = AgentAccess.for_member(workspace.id, member)

    account =
      Repo.insert!(%Account{
        workspace_id: workspace.id,
        member_id: member.id,
        provider: "imap",
        email_address: "worker-fixture@example.com",
        settings: %{"password" => "not-public"}
      })

    message =
      Repo.insert!(%Message{
        workspace_id: workspace.id,
        mail_account_id: account.id,
        provider_message_id: "fixture-message",
        subject: "Receipt",
        body_text: "Invoice total 12 EUR",
        body_html: "not-public",
        provider_metadata: %{"reader_version" => 1}
      })

    %{workspace: workspace, member: member, access: access, account: account, message: message}
  end

  defp request(conn, body) do
    conn
    |> put_req_header("authorization", "Bearer test-token")
    |> post("/api/worker/mail/tools", body)
  end

  test "requires worker authentication and a distinct live mailbox access token", c do
    conn =
      post(c.conn, "/api/worker/mail/tools", %{
        access_token: c.access.token,
        action: "list",
        arguments: %{}
      })

    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    conn = request(build_conn(), %{access_token: "forged", action: "list", arguments: %{}})
    assert json_response(conn, 403)["error"]["code"] == "mail_access_denied"
  end

  test "valid authority yields safe metadata and no-store responses", c do
    conn = request(c.conn, %{access_token: c.access.token, action: "list", arguments: %{}})
    data = json_response(conn, 200)["data"]
    assert [%{"id" => id, "message_count" => 1}] = data["accounts"]
    assert id == c.account.id
    assert data["coverage"]["exhaustive"] == false
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    refute conn.resp_body =~ "not-public"
    refute conn.resp_body =~ c.access.token
  end

  test "read only returns text and metadata and workspace scope cannot be replaced", c do
    conn =
      request(c.conn, %{
        access_token: c.access.token,
        action: "read",
        arguments: %{message_id: c.message.id}
      })

    assert json_response(conn, 200)["data"]["message"]["body_text"] == "Invoice total 12 EUR"
    refute conn.resp_body =~ "not-public"

    conn =
      request(build_conn(), %{
        access_token: c.access.token,
        action: "search",
        arguments: %{workspace_id: Ecto.UUID.generate()}
      })

    assert json_response(conn, 422)["error"]["code"] == "invalid_mail_tool_request"
  end

  test "unknown actions or malformed argument types cannot become worker requests", c do
    for args <- [
          %{action: "send", arguments: %{}},
          %{action: "read", arguments: []},
          %{action: "list"}
        ] do
      conn = request(build_conn(), Map.put(args, :access_token, c.access.token))
      assert json_response(conn, 422)["error"]["code"] == "invalid_mail_tool_request"
    end
  end

  test "coordinator conversation authority cannot export or impersonate an agent", c do
    conn =
      request(c.conn, %{
        access_token: c.access.token,
        action: "save_attachment",
        arguments: %{message_id: c.message.id, attachment_id: "a"}
      })

    assert json_response(conn, 403)["error"]["code"] == "mail_access_denied"

    conn =
      request(build_conn(), %{
        access_token: c.access.token,
        acting_agent_id: Ecto.UUID.generate(),
        action: "list",
        arguments: %{}
      })

    assert json_response(conn, 403)["error"]["code"] == "mail_access_denied"
  end

  test "revoked member authority is rejected without returning cached messages", c do
    Repo.update!(Ecto.Changeset.change(c.member, status: "suspended"))

    conn =
      request(c.conn, %{
        access_token: c.access.token,
        action: "read",
        arguments: %{message_id: c.message.id}
      })

    assert json_response(conn, 403)["error"]["code"] == "mail_access_denied"
    refute conn.resp_body =~ "Invoice total"
  end

  test "refresh requires worker authentication and never extends conversation authority", c do
    body = %{access_token: c.access.token, action: "list"}
    conn = post(c.conn, "/api/worker/mail/refresh", body)
    assert json_response(conn, 401)["error"]["code"] == "unauthorized"

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer test-token")
      |> post("/api/worker/mail/refresh", body)

    assert json_response(conn, 403)["error"]["code"] == "mail_access_denied"
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    refute conn.resp_body =~ c.access.token
  end

  test "HTTP refresh recovers a checkpoint older than 24h without expanding its scope", c do
    agent =
      Repo.insert!(%Mokaid.Agents.Agent{
        workspace_id: c.workspace.id,
        kind: "ai",
        display_name: "Recovered reader",
        slug: "recovered-reader",
        ai_enabled: true,
        status: "idle"
      })

    {:ok, task} =
      Mokaid.Tasks.create_task(
        c.workspace.id,
        %{"title" => "Read invoices", "assigned_agent_id" => agent.id, "status" => "in_progress"},
        c.member
      )

    {:ok, run} = Mokaid.Tasks.create_execution_run(task, %{"instruction" => "Read invoices"})
    access = AgentAccess.for_run(run, task)
    salt = "workspace-mail-tools-v1"
    {:ok, claims} = Phoenix.Token.verify(MokaidWeb.Endpoint, salt, access.token, max_age: 86_400)

    expired =
      Phoenix.Token.sign(
        MokaidWeb.Endpoint,
        salt,
        Map.put(claims, "expires_at", System.system_time(:second) - 100),
        signed_at: System.system_time(:second) - 86_500
      )

    assert {:error, :expired} =
             Phoenix.Token.verify(MokaidWeb.Endpoint, salt, expired, max_age: 86_400)

    denied =
      request(c.conn, %{
        access_token: expired,
        acting_agent_id: agent.id,
        action: "read",
        arguments: %{message_id: c.message.id}
      })

    assert json_response(denied, 403)["error"]["code"] == "mail_access_denied"

    refreshed =
      build_conn()
      |> put_req_header("authorization", "Bearer test-token")
      |> post("/api/worker/mail/refresh", %{
        access_token: expired,
        action: "read",
        acting_agent_id: agent.id,
        workspace_id: Ecto.UUID.generate(),
        allowed_agent_ids: [Ecto.UUID.generate()]
      })

    assert %{"token" => token} = json_response(refreshed, 200)["data"]
    assert get_resp_header(refreshed, "cache-control") == ["private, no-store"]
    {:ok, renewed} = Phoenix.Token.verify(MokaidWeb.Endpoint, salt, token, max_age: 86_400)
    assert Map.delete(renewed, "expires_at") == Map.delete(claims, "expires_at")
    assert renewed["expires_at"] > System.system_time(:second)

    read =
      request(build_conn(), %{
        access_token: token,
        action: "read",
        acting_agent_id: agent.id,
        arguments: %{message_id: c.message.id}
      })

    assert json_response(read, 200)["data"]["message"]["body_text"] == "Invoice total 12 EUR"
    refute read.resp_body =~ token

    denied =
      request(build_conn(), %{
        access_token: token,
        action: "read",
        acting_agent_id: Ecto.UUID.generate(),
        arguments: %{message_id: c.message.id}
      })

    assert json_response(denied, 403)["error"]["code"] == "mail_access_denied"
  end
end
