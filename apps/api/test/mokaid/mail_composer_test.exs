defmodule Mokaid.MailComposerTest do
  use Mokaid.DataCase, async: false
  alias Mokaid.Mail.{Account, Composer, Message, Outbox}
  alias Mokaid.Vault

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
      "subject" => "Hello",
      "body_text" => "Test only"
    }

    credentials = fn account -> {:ok, %{id: account.id, email_address: account.email_address}} end

    %{
      workspace: workspace,
      member: member,
      account: account,
      params: params,
      credentials: credentials
    }
  end

  test "provider accepted send stores Sent message, fixes sender and is never sent twice", c do
    dispatch = fn payload ->
      Process.put(:submissions, Process.get(:submissions, 0) + 1)
      assert payload.account.email_address == c.account.email_address
      refute Map.has_key?(payload.message, "from")
      {:ok, %{"status" => "sent", "provider_message_id" => "provider-1"}}
    end

    params = Map.put(c.params, "from", "forged@example.com")
    opts = [credentials: c.credentials, dispatch: dispatch]

    assert {:ok, %{status: "sent", message_id: id} = first} =
             Composer.send(c.workspace.id, c.member, params, opts)

    assert {:ok, ^first} = Composer.send(c.workspace.id, c.member, params, opts)
    assert Process.get(:submissions) == 1
    message = Repo.get!(Message, id)
    assert message.folder == "sent"
    assert message.from_email == c.account.email_address
    assert message.is_read

    assert {:error, :idempotency_conflict} =
             Composer.send(c.workspace.id, c.member, Map.put(params, "subject", "Changed"), opts)
  end

  test "lost response remains unknown across retry without resubmission", c do
    dispatch = fn _ ->
      Process.put(:submissions, Process.get(:submissions, 0) + 1)
      {:error, :mail_send_uncertain}
    end

    opts = [credentials: c.credentials, dispatch: dispatch]

    assert {:ok, %{status: "unknown", error: "delivery_unknown"} = first} =
             Composer.send(c.workspace.id, c.member, c.params, opts)

    assert {:ok, ^first} = Composer.send(c.workspace.id, c.member, c.params, opts)
    assert Process.get(:submissions) == 1
    assert Repo.aggregate(Message, :count) == 0
  end

  test "concurrent same request observes the claim and does not submit", c do
    parent = self()

    dispatch = fn _ ->
      send(parent, :provider_started)

      receive do
        :continue -> {:ok, %{"status" => "sent"}}
      end
    end

    task =
      Task.async(fn ->
        Composer.send(c.workspace.id, c.member, c.params,
          credentials: c.credentials,
          dispatch: dispatch
        )
      end)

    assert_receive :provider_started

    assert {:ok, %{status: "sending"}} =
             Composer.send(c.workspace.id, c.member, c.params,
               credentials: c.credentials,
               dispatch: fn _ -> flunk("duplicate provider submission") end
             )

    send(task.pid, :continue)
    assert {:ok, %{status: "sent"}} = Task.await(task)
  end

  test "header injection, invalid addresses and oversized payloads fail before claiming", c do
    for patch <- [
          %{"to" => ["ok@example.com\r\nBcc: hidden@example.com"]},
          %{"to" => ["Name <ok@example.com>"]},
          %{"subject" => "Hi\r\nFrom: attacker@example.com"},
          %{"request_id" => "not-a-uuid"},
          %{"body_text" => String.duplicate("a", 200_001)},
          %{
            "attachments" => [
              %{"filename" => "../x", "content_type" => "text/plain", "content_base64" => "eA=="}
            ]
          },
          %{
            "attachments" => [
              %{"filename" => "x", "content_type" => "text/plain", "content_base64" => "INVALID"}
            ]
          },
          %{
            "attachments" =>
              List.duplicate(
                %{"filename" => "x", "content_type" => "text/plain", "content_base64" => "eA=="},
                11
              )
          }
        ] do
      assert {:error, :invalid_message} =
               Composer.send(c.workspace.id, c.member, Map.merge(c.params, patch))
    end

    assert Repo.aggregate(Outbox, :count) == 0
  end

  test "workspace, inactive account and permissions are checked on the server", c do
    {other, other_user} = workspace_fixture()
    other_member = owner_member(other, other_user)
    assert {:error, :not_found} = Composer.send(other.id, other_member, c.params)
    assert {:error, :forbidden} = Composer.send(other.id, c.member, c.params)
    Repo.update!(Ecto.Changeset.change(c.account, status: "paused"))
    assert {:error, :not_found} = Composer.send(c.workspace.id, c.member, c.params)
    Repo.update!(Ecto.Changeset.change(c.account, status: "active"))
    role = Repo.get_by!(Mokaid.Members.Role, workspace_id: c.workspace.id, name: "Member")
    Repo.update!(Ecto.Changeset.change(c.member, role_id: role.id))
    assert {:error, :forbidden} = Composer.send(c.workspace.id, c.member, c.params)
  end

  test "background sync timestamp changes permit send; credential changes stop it", c do
    timestamp_credentials = fn account ->
      Repo.update!(Ecto.Changeset.change(account, last_sync_at: DateTime.utc_now()))
      c.credentials.(account)
    end

    assert {:ok, %{status: "sent"}} =
             Composer.send(c.workspace.id, c.member, c.params,
               credentials: timestamp_credentials,
               dispatch: fn _ -> {:ok, %{"status" => "sent"}} end
             )

    changed_credentials = fn account ->
      Repo.update!(
        Ecto.Changeset.change(account,
          encrypted_credentials: Vault.encrypt(%{"password" => "changed"})
        )
      )

      c.credentials.(account)
    end

    assert {:ok, %{status: "failed", error: "authentication_required"}} =
             Composer.send(
               c.workspace.id,
               c.member,
               Map.put(c.params, "request_id", Ecto.UUID.generate()),
               credentials: changed_credentials,
               dispatch: fn _ -> flunk("must not send changed credentials") end
             )
  end

  test "revoked permission during credential refresh stops submission", c do
    credentials = fn account ->
      Repo.update!(Ecto.Changeset.change(c.member, status: "suspended"))
      c.credentials.(account)
    end

    assert {:ok, %{status: "failed"}} =
             Composer.send(c.workspace.id, c.member, c.params,
               credentials: credentials,
               dispatch: fn _ -> flunk("must not submit") end
             )
  end

  test "definite refusal is safe, sanitized, and also never retried implicitly", c do
    assert {:ok, %{status: "failed", error: "provider_rejected"}} =
             Composer.send(c.workspace.id, c.member, c.params,
               credentials: c.credentials,
               dispatch: fn _ ->
                 {:ok, %{"status" => "failed", "error" => "secret-token-echo"}}
               end
             )

    assert {:ok, %{status: "failed"}} =
             Composer.send(c.workspace.id, c.member, c.params,
               credentials: c.credentials,
               dispatch: fn _ -> flunk("must not resubmit") end
             )
  end

  test "reply identity is scoped and RFC headers are derived from the stored message", c do
    message =
      Repo.insert!(%Message{
        workspace_id: c.workspace.id,
        mail_account_id: c.account.id,
        provider_message_id: "original",
        rfc_message_id: "<original@example.com>",
        references: ["<first@example.com>"],
        thread_id: "thread"
      })

    params = Map.put(c.params, "in_reply_to", message.id)

    assert {:ok, %{status: "sent"}} =
             Composer.send(c.workspace.id, c.member, params,
               credentials: c.credentials,
               dispatch: fn %{message: envelope} ->
                 assert envelope["in_reply_to"] == "<original@example.com>"
                 assert envelope["references"] == ["<first@example.com>"]
                 assert envelope["thread_id"] == "thread"
                 {:ok, %{"status" => "sent"}}
               end
             )

    assert {:error, :invalid_reply} =
             Composer.send(
               c.workspace.id,
               c.member,
               params
               |> Map.put("in_reply_to", Ecto.UUID.generate())
               |> Map.put("request_id", Ecto.UUID.generate())
             )
  end

  test "sent attachments remain encrypted and readable only by the exact workspace/message", c do
    attachment = %{
      "filename" => "note.txt",
      "content_type" => "text/plain",
      "content_base64" => Base.encode64("private attachment")
    }

    assert {:ok, %{message_id: message_id, id: outbox_id}} =
             Composer.send(
               c.workspace.id,
               c.member,
               Map.put(c.params, "attachments", [attachment]),
               credentials: c.credentials,
               dispatch: fn _ -> {:ok, %{"status" => "sent"}} end
             )

    entry = Repo.get!(Outbox, outbox_id)
    refute entry.encrypted_attachments =~ "private attachment"

    assert {:ok, %{filename: "note.txt", size: 18}} =
             Composer.outgoing_attachment(c.workspace.id, message_id, "0")

    assert {:error, :not_found} =
             Composer.outgoing_attachment(Ecto.UUID.generate(), message_id, "0")

    assert {:error, :not_found} = Composer.outgoing_attachment(c.workspace.id, message_id, "-1")
    assert {:error, :not_found} = Composer.outgoing_attachment(c.workspace.id, message_id, "1")
  end

  test "outbox survives account deletion and cannot be polled by another member", c do
    assert {:ok, %{id: id}} =
             Composer.send(c.workspace.id, c.member, c.params,
               credentials: c.credentials,
               dispatch: fn _ -> {:ok, %{"status" => "sent"}} end
             )

    Repo.delete!(c.account)
    assert %{account_id: nil, status: "sent"} = Repo.get!(Outbox, id)

    assert {:ok, %{status: "sent", id: ^id}} =
             Composer.send(c.workspace.id, c.member, c.params,
               dispatch: fn _ -> flunk("never re-send after disconnect") end
             )

    {other, other_user} = workspace_fixture()
    assert {:error, :not_found} = Composer.status(other.id, owner_member(other, other_user), id)
    assert {:ok, %{status: "sent"}} = Composer.status(c.workspace.id, c.member, id)
  end
end
