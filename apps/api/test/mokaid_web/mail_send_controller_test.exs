defmodule MokaidWeb.MailSendControllerTest do
  use MokaidWeb.ConnCase, async: false
  alias Mokaid.Auth.Token
  alias Mokaid.Mail.{Account, Composer}

  setup do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)

    account =
      Repo.insert!(%Account{
        workspace_id: workspace.id,
        member_id: member.id,
        provider: "imap",
        email_address: "sender@example.com",
        status: "active"
      })

    params = %{
      "request_id" => Ecto.UUID.generate(),
      "account_id" => account.id,
      "to" => ["recipient@example.com"],
      "subject" => "Fixture only",
      "body_text" => "No provider call",
      "attachments" => [
        %{
          "filename" => "fixture.txt",
          "content_type" => "text/plain",
          "content_base64" => Base.encode64("Fixture attachment")
        }
      ]
    }

    {:ok, sent} =
      Composer.send(workspace.id, member, params,
        credentials: fn _ -> {:ok, %{}} end,
        dispatch: fn _ -> {:ok, %{"status" => "sent"}} end
      )

    %{
      workspace: workspace,
      user: user,
      member: member,
      account: account,
      params: params,
      sent: sent
    }
  end

  defp authenticated(conn, user, workspace) do
    conn
    |> put_req_header("authorization", "Bearer " <> Token.sign(user.id))
    |> put_req_header("x-workspace-id", workspace.id)
  end

  test "HTTP retry returns the durable receipt without submitting again", c do
    response =
      c.conn
      |> authenticated(c.user, c.workspace)
      |> post("/api/mail/send", c.params)
      |> json_response(200)

    assert response["data"]["status"] == "sent"
    assert response["data"]["id"] == c.sent.id

    status =
      c.conn
      |> authenticated(c.user, c.workspace)
      |> get("/api/mail/outbox/#{c.sent.id}")
      |> json_response(200)

    assert status == response
  end

  test "cross-workspace reads cannot access outbox or attachment bytes", c do
    {other, user} = workspace_fixture()

    for path <- [
          "/api/mail/outbox/#{c.sent.id}",
          "/api/mail/messages/#{c.sent.message_id}/attachments/0"
        ] do
      assert c.conn |> authenticated(user, other) |> get(path) |> json_response(404)
    end
  end

  test "attachment response is download-only and never cached", c do
    conn =
      c.conn
      |> authenticated(c.user, c.workspace)
      |> get("/api/mail/messages/#{c.sent.message_id}/attachments/0")

    assert response(conn, 200) == "Fixture attachment"
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment;"
    assert disposition =~ "fixture.txt"
  end

  test "viewer cannot submit or mutate a message even with a valid account", c do
    role = Repo.get_by!(Mokaid.Members.Role, name: "Viewer")
    c.member |> Ecto.Changeset.change(role_id: role.id) |> Repo.update!()

    assert c.conn
           |> authenticated(c.user, c.workspace)
           |> post("/api/mail/send", c.params)
           |> json_response(403)

    assert c.conn
           |> authenticated(c.user, c.workspace)
           |> patch("/api/mail/messages/#{c.sent.message_id}", %{action: "trash"})
           |> json_response(403)
  end
end
