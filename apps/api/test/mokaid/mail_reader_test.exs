defmodule Mokaid.MailReaderTest do
  use Mokaid.DataCase, async: false
  alias Mokaid.{Mail, Repo, Vault}
  alias Mokaid.Mail.{Account, Attachments, Message, MessageActions, WorkerRPC}

  setup do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)

    account =
      Repo.insert!(%Account{
        workspace_id: workspace.id,
        member_id: member.id,
        provider: "imap",
        email_address: "reader@example.com",
        encrypted_credentials: Vault.encrypt(%{"username" => "reader", "password" => "secret"})
      })

    previous = Application.get_env(:mokaid, :ai_worker)
    previous_http = Application.get_env(:mokaid, :mail_worker_http_options)

    Application.put_env(:mokaid, :ai_worker,
      url: "http://worker.test",
      token: "internal-test-token",
      dispatch: :http
    )

    Application.put_env(:mokaid, :mail_worker_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :ai_worker, previous)
      Application.put_env(:mokaid, :mail_worker_http_options, previous_http)
    end)

    %{workspace: workspace, account: account}
  end

  defp message(account, attrs) do
    {:ok, _} =
      Mail.ingest_messages(account, [
        Map.merge(
          %{
            "provider_message_id" => Ecto.UUID.generate(),
            "received_at" => DateTime.to_iso8601(DateTime.utc_now()),
            "folder" => "inbox"
          },
          attrs
        )
      ])

    Mail.list_messages(account.workspace_id, account_id: account.id, limit: 200)
    |> Enum.find(&(&1.provider_message_id == attrs["provider_message_id"])) ||
      Mail.list_messages(account.workspace_id, account_id: account.id, limit: 1) |> List.first()
  end

  test "folder/filter/search/sort pagination and counts remain workspace scoped", %{
    account: account,
    workspace: workspace
  } do
    for index <- 1..5 do
      message(account, %{
        "provider_message_id" => "item-#{index}",
        "subject" => "Subject #{index}",
        "folder" => if(index == 5, do: "sent", else: "inbox"),
        "is_read" => rem(index, 2) == 0,
        "is_starred" => index == 1,
        "labels" => ["Label_abc"]
      })
    end

    page =
      Mail.page_messages(workspace.id,
        folder: "inbox",
        filter: "unread",
        sort: "subject",
        limit: 1
      )

    assert page.meta == %{total: 2, limit: 1, offset: 0, has_more: true}
    assert hd(page.messages).subject == "Subject 1"

    assert hd(
             Mail.page_messages(workspace.id,
               folder: "inbox",
               filter: "unread",
               sort: "subject",
               limit: 1,
               offset: 1
             ).messages
           ).subject == "Subject 3"

    assert Mail.page_messages(workspace.id, folder: "sent").meta.total == 1
    assert Mail.page_messages(workspace.id, folder: "starred").meta.total == 1

    assert Mail.page_messages(workspace.id, label: "Label_abc", search: "Subject 2").meta.total ==
             1

    assert Mail.page_messages(Ecto.UUID.generate(), folder: "all").meta.total == 0
    assert Mail.page_messages(workspace.id, account_id: "malformed").meta.total == 0
    folders = Mail.list_folders(workspace.id)
    assert Enum.find(folders.data, &(&1.key == "inbox")).count == 4
    assert folders.meta.labels == [%{name: "Label_abc", count: 5}]
  end

  test "Gmail non-exclusive system labels belong to every matching main folder", %{
    account: account,
    workspace: workspace
  } do
    gmail = Repo.update!(Ecto.Changeset.change(account, provider: "gmail"))

    message(gmail, %{
      "provider_message_id" => "self-sent",
      "folder" => "inbox",
      "labels" => ["INBOX", "SENT"]
    })

    message(gmail, %{
      "provider_message_id" => "draft-inbox",
      "folder" => "drafts",
      "labels" => ["INBOX", "DRAFT"]
    })

    message(gmail, %{
      "provider_message_id" => "trashed-sent",
      "folder" => "trash",
      "labels" => ["SENT", "TRASH"]
    })

    message(gmail, %{
      "provider_message_id" => "spam-sent",
      "folder" => "spam",
      "labels" => ["SENT", "SPAM"]
    })

    assert Mail.page_messages(workspace.id, folder: "inbox").meta.total == 2
    assert Mail.page_messages(workspace.id, folder: "sent").meta.total == 1
    assert Mail.page_messages(workspace.id, folder: "drafts").meta.total == 1
    counts = Mail.list_folders(workspace.id).data
    assert Enum.find(counts, &(&1.key == "sent")).count == 1
    assert Enum.find(counts, &(&1.key == "trash")).count == 1
  end

  test "another provider's category named SENT never changes folder membership", %{
    account: account,
    workspace: workspace
  } do
    message(account, %{
      "provider_message_id" => "custom-label",
      "folder" => "inbox",
      "labels" => ["SENT"]
    })

    assert Mail.page_messages(workspace.id, folder: "sent").meta.total == 0
    assert Mail.page_messages(workspace.id, folder: "inbox").meta.total == 1
  end

  test "metadata-only refresh preserves AI analysis and body while updating flags", %{
    account: account
  } do
    original =
      message(account, %{
        "provider_message_id" => "known",
        "ai_importance" => 71,
        "ai_summary" => "Existing",
        "body_text" => "Stored",
        "is_read" => false
      })

    assert {:ok, 0} =
             Mail.ingest_messages(account, [
               %{"provider_message_id" => "known", "is_read" => true}
             ])

    updated = Repo.get!(Message, original.id)
    assert updated.is_read
    assert updated.ai_importance == 71
    assert updated.ai_summary == "Existing"
    assert updated.body_text == "Stored"
  end

  test "provider tombstone cannot remove a different workspace or moved destination", %{
    account: account
  } do
    original = message(account, %{"provider_message_id" => "moved", "folder" => "trash"})

    {:ok, 0} =
      Mail.ingest_messages(account, [
        %{"provider_message_id" => "moved", "_removed" => true, "_from_folder" => "inbox"}
      ])

    assert Repo.get!(Message, original.id)

    {:ok, 0} =
      Mail.ingest_messages(account, [
        %{"provider_message_id" => "moved", "_removed" => true, "_from_folder" => "trash"}
      ])

    refute Repo.get(Message, original.id)
  end

  test "legacy details hydrate once with exact account and RFC headers", %{account: account} do
    original = message(account, %{"provider_message_id" => "7:1"})

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/mail/message/detail"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer internal-test-token"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = Jason.decode!(body)
      assert data["account"]["id"] == account.id
      assert data["message"]["mail_account_id"] == account.id

      Req.Test.json(conn, %{
        message: %{
          body_text: "Real text",
          body_html: "<b>Real</b>",
          rfc_message_id: "<original@example.com>",
          references: ["<previous@example.com>"],
          attachments: [
            %{id: "attachment", filename: "file.pdf", mime_type: "application/pdf", size: 4}
          ],
          has_attachments: true,
          provider_metadata: %{reader_version: 1}
        }
      })
    end)

    assert {:ok, hydrated} = MessageActions.hydrate(original)
    assert hydrated.body_html == "<b>Real</b>"
    assert hydrated.rfc_message_id == "<original@example.com>"
    assert [%{"id" => "attachment"}] = hydrated.attachments
    assert {:ok, ^hydrated} = MessageActions.hydrate(hydrated)
  end

  test "failed provider action never reports local success", %{account: account} do
    original = message(account, %{"provider_message_id" => "7:1", "is_read" => false})
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{error: "auth_failed"}) end)
    assert {:error, :mail_reconnect_required} = MessageActions.apply(original, "read", true)
    refute Repo.get!(Message, original.id).is_read
    assert {:error, :invalid_mail_action} = MessageActions.apply(original, "delete", true)
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{changes: %{is_read: true}}) end)
    assert {:ok, updated} = MessageActions.apply(original, "read", true)
    assert updated.is_read
  end

  test "download permits only manifest attachments and checks actual byte count", %{
    account: account
  } do
    original =
      message(account, %{
        "provider_message_id" => "7:1",
        "attachments" => [
          %{
            "id" => "a",
            "filename" => "unsafe\r\n/file.pdf",
            "mime_type" => "application/pdf",
            "size" => 4
          }
        ]
      })

    assert {:error, :not_found} = Attachments.download(original, "other")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/mail/attachment"
      Req.Test.json(conn, %{content_base64: Base.encode64("data")})
    end)

    assert {:ok, result} = Attachments.download(original, "a")
    assert result.bytes == "data"
    refute result.filename =~ "\r"
    refute result.filename =~ "/"
    assert result.mime_type == "application/octet-stream"
  end

  test "invalid worker bodies are failures and send ambiguity is retained" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end)
    assert {:error, :mail_worker_unavailable} = WorkerRPC.post("/mail/message/detail", %{})
    assert {:error, :mail_send_uncertain} = WorkerRPC.post("/mail/send", %{})

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{status: "unknown", error: "delivery_unknown"})
    end)

    assert {:ok, %{"status" => "unknown", "error" => "delivery_unknown"}} =
             WorkerRPC.post("/mail/send", %{})
  end

  test "body limits preserve valid UTF-8", %{account: account} do
    saved =
      message(account, %{
        "provider_message_id" => "utf8",
        "body_text" => String.duplicate("é", 210_000)
      })

    assert String.valid?(saved.body_text)
    assert String.length(saved.body_text) == 200_000
  end
end
