defmodule Mokaid.MailAgentToolsTest do
  use Mokaid.DataCase, async: false
  alias Mokaid.{Agents, Drive, Mail, Tasks, Vault}
  alias Mokaid.Mail.{Account, AgentTools, Message}
  alias Mokaid.Integrations.{IntegrationConnection, IntegrationProvider}
  alias Mokaid.Drive.DriveItem

  defmodule StorageFixture do
    @behaviour Plug
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:stored, conn.method, conn.request_path, body, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, "")
    end
  end

  setup do
    {workspace, user} = workspace_fixture()
    member = owner_member(workspace, user)

    {:ok, agent} =
      Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Mail reader"})

    {:ok, task} =
      Tasks.create_task(
        workspace.id,
        %{"title" => "Collect invoices", "assigned_agent_id" => agent.id},
        member
      )

    account =
      Repo.insert!(%Account{
        workspace_id: workspace.id,
        member_id: member.id,
        provider: "imap",
        email_address: "invoice@example.com",
        encrypted_credentials:
          Vault.encrypt(%{"username" => "invoice", "password" => "never-expose"}),
        settings: %{"host" => "private-host"},
        sync_state: %{"secret_cursor" => "never-expose"}
      })

    context = %{
      workspace_id: workspace.id,
      member: member,
      agent_id: agent.id,
      task_id: task.id,
      run_id: Ecto.UUID.generate(),
      reauthorize: fn -> {:ok, %{}} end
    }

    replace_env(:mokaid, :ai_worker,
      url: "http://worker.test",
      token: "test-token",
      dispatch: :http
    )

    replace_env(:mokaid, :mail_worker_http_options, plug: {Req.Test, __MODULE__})

    %{
      workspace: workspace,
      member: member,
      agent: agent,
      task: task,
      account: account,
      context: context
    }
  end

  defp message(account, attrs \\ %{}) do
    Repo.insert!(
      Message.changeset(
        %Message{},
        Map.merge(
          %{
            "workspace_id" => account.workspace_id,
            "mail_account_id" => account.id,
            "provider_message_id" => Ecto.UUID.generate(),
            "subject" => "Invoice",
            "body_text" => "Amount due 42 EUR",
            "body_html" => "<script>never-expose</script>",
            "received_at" => ~U[2026-09-01 10:00:00.000000Z],
            "provider_metadata" => %{"reader_version" => 1, "secret" => "never-expose"},
            "folder" => "inbox",
            "is_read" => false
          },
          attrs
        )
      )
    )
  end

  defp attachment_message(account, attrs \\ %{}) do
    message(
      account,
      Map.merge(
        %{
          "has_attachments" => true,
          "attachments" => [
            %{
              "id" => "part-1",
              "filename" => "invoice.pdf",
              "mime_type" => "application/pdf",
              "size" => 20,
              "provider_id" => "never-expose"
            }
          ]
        },
        attrs
      )
    )
  end

  defp oauth_account(c, provider, email) do
    key = if provider == "microsoft", do: "outlook", else: "gmail"

    catalog =
      Repo.insert!(%IntegrationProvider{key: key, name: key, category: "communication"},
        on_conflict: {:replace, [:name]},
        conflict_target: :key,
        returning: true
      )

    connection =
      Repo.insert!(%IntegrationConnection{
        workspace_id: c.workspace.id,
        provider_id: catalog.id,
        connected_by_member_id: c.member.id,
        connected_account: email,
        status: "connected",
        encrypted_credentials: <<"unreadable-by-design-no-credential-decrypt">>
      })

    account =
      Repo.insert!(%Account{
        workspace_id: c.workspace.id,
        member_id: c.member.id,
        provider: provider,
        email_address: email,
        connection_id: connection.id
      })

    {account, connection}
  end

  defp storage_fixture do
    server =
      start_supervised!(
        {Bandit, plug: {StorageFixture, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    replace_env(:ex_aws, :s3,
      access_key_id: "fixture-access",
      secret_access_key: "fixture-secret",
      region: "us-east-1",
      scheme: "http://",
      host: "127.0.0.1",
      port: port,
      retries: [max_attempts: 1, base_backoff_in_ms: 0, max_backoff_in_ms: 0]
    )

    replace_env(:mokaid, :storage, bucket_uploads: "fixture-bucket")
  end

  defp replace_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  test "inventory and search project only safe metadata with explicit partial coverage", c do
    attachment_message(c.account)
    {:ok, listed} = AgentTools.call(c.context, "list", %{})
    assert [%{id: id, message_count: 1}] = listed.accounts
    assert id == c.account.id
    refute listed.coverage.exhaustive
    {:ok, found} = AgentTools.call(c.context, "search", %{})
    assert length(found.messages) == 1
    assert found.pagination.total == 1
    encoded = Jason.encode!(%{list: listed, search: found})

    for secret <- [
          "never-expose",
          "private-host",
          "body_html",
          "encrypted_credentials",
          "settings",
          "sync_state",
          "provider_id"
        ] do
      refute encoded =~ secret
    end
  end

  test "all three providers use one scoped account and message interface", c do
    for provider <- ~w(gmail microsoft) do
      {account, _} = oauth_account(c, provider, "#{provider}@example.com")

      attachment_message(account)
    end

    attachment_message(c.account)
    {:ok, found} = AgentTools.call(c.context, "search", %{})
    assert found.pagination.total == 3

    for account <- Mail.list_accounts(c.workspace.id) do
      {:ok, found} = AgentTools.call(c.context, "search", %{"account_id" => account.id})
      assert [%{account_id: id}] = found.messages
      assert id == account.id
    end
  end

  test "date boundaries are inclusive UTC and pagination/search/body filters are precise", c do
    for {subject, date} <- [
          {"Invoice start", ~U[2026-09-01 00:00:00.000000Z]},
          {"Invoice end", ~U[2026-09-30 23:59:59.999999Z]},
          {"Invoice later", ~U[2026-10-01 00:00:00.000000Z]}
        ] do
      attachment_message(c.account, %{"subject" => subject, "received_at" => date})
    end

    args = %{
      "account" => " INVOICE@EXAMPLE.COM ",
      "query" => "amount due",
      "date_from" => "2026-09-01",
      "date_to" => "2026-09-30",
      "has_attachments" => true,
      "per_page" => 1
    }

    {:ok, first} = AgentTools.call(c.context, "search", args)
    assert first.pagination == %{page: 1, per_page: 1, total: 2, has_more: true}
    assert hd(first.messages).subject == "Invoice end"
    {:ok, second} = AgentTools.call(c.context, "search", Map.put(args, "page", 2))
    assert hd(second.messages).subject == "Invoice start"
    refute second.pagination.has_more
  end

  test "literal wildcard query never broadens the requested search", c do
    message(c.account, %{"subject" => "100% paid"})
    message(c.account, %{"subject" => "Other"})
    {:ok, found} = AgentTools.call(c.context, "search", %{"query" => "%"})
    assert found.pagination.total == 1
  end

  test "unknown account and cross-workspace messages fail closed", c do
    {other, user} = workspace_fixture()
    other_member = owner_member(other, user)

    account =
      Repo.insert!(%Account{
        workspace_id: other.id,
        member_id: other_member.id,
        provider: "gmail",
        email_address: "other@example.com"
      })

    message = message(account)

    assert {:error, :mail_account_not_found} =
             AgentTools.call(c.context, "search", %{"account_id" => account.id})

    assert {:error, :mail_message_not_found} =
             AgentTools.call(c.context, "read", %{"message_id" => message.id})

    {:ok, list} = AgentTools.call(c.context, "list", %{})
    assert length(list.accounts) == 1
  end

  test "same email on multiple transports requires exact account ID", c do
    Repo.insert!(%Account{
      workspace_id: c.workspace.id,
      member_id: c.member.id,
      provider: "gmail",
      email_address: c.account.email_address
    })

    assert {:error, :mail_account_ambiguous} =
             AgentTools.call(c.context, "search", %{"account" => c.account.email_address})
  end

  test "malformed arguments, scope injection and unsupported writes are rejected", c do
    for args <- [
          %{"page" => -1},
          %{"per_page" => 51},
          %{"date_from" => "yesterday"},
          %{"date_to" => "2026-02-30"},
          %{"date_from" => "2026-09-30", "date_to" => "2026-09-01"},
          %{"has_attachments" => "true"},
          %{"account_id" => "bad"},
          %{"workspace_id" => Ecto.UUID.generate()},
          %{"query" => %{}},
          %{"query" => String.duplicate("x", 501)}
        ] do
      assert {:error, :invalid_mail_tool_request} = AgentTools.call(c.context, "search", args)
    end

    assert {:error, :invalid_mail_tool_request} = AgentTools.call(c.context, "send", %{})

    assert {:error, :mail_access_denied} =
             AgentTools.call(Map.delete(c.context, :reauthorize), "list", %{})
  end

  test "read returns bounded plain text and manifest without changing unread state", c do
    message = attachment_message(c.account, %{"body_text" => String.duplicate("é", 60_000)})
    {:ok, read} = AgentTools.call(c.context, "read", %{"message_id" => message.id})
    assert String.length(read.message.body_text) == 50_000
    assert read.message.body_truncated
    assert hd(read.message.attachments).filename == "invoice.pdf"
    refute Jason.encode!(read) =~ "never-expose"
    refute Repo.get!(Message, message.id).is_read
  end

  test "legacy read uses scoped provider hydration and reports cached fallback failure", c do
    message = message(c.account, %{"provider_metadata" => %{}})

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body)["account"]["id"] == c.account.id

      Req.Test.json(conn, %{
        message: %{
          body_text: "Fresh provider text",
          body_html: "<b>never-expose</b>",
          provider_metadata: %{reader_version: 1}
        }
      })
    end)

    {:ok, read} = AgentTools.call(c.context, "read", %{"message_id" => message.id})
    assert read.message.body_text == "Fresh provider text"
    assert is_nil(read.hydration_error)
    other = message(c.account, %{"provider_metadata" => %{}})

    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{error: "provider_unavailable"}) end)

    {:ok, read} = AgentTools.call(c.context, "read", %{"message_id" => other.id})
    assert read.hydration_error == "mail_details_unavailable"
    assert read.message.body_text == "Amount due 42 EUR"
  end

  test "revocation while hydrating cannot publish cached or fresh content", c do
    message = message(c.account, %{"provider_metadata" => %{}})
    Process.put(:mail_test_authorized, true)

    context = %{
      c.context
      | reauthorize: fn ->
          if Process.get(:mail_test_authorized), do: {:ok, %{}}, else: {:error, :denied}
        end
    }

    Req.Test.stub(__MODULE__, fn conn ->
      Process.put(:mail_test_authorized, false)

      Req.Test.json(conn, %{
        message: %{body_text: "must not publish", provider_metadata: %{reader_version: 1}}
      })
    end)

    assert {:error, :mail_access_denied} =
             AgentTools.call(context, "read", %{"message_id" => message.id})
  end

  test "export stores exact provider bytes once with task provenance and reusable folder", c do
    storage_fixture()
    message = attachment_message(c.account)
    payload = "%PDF-synthetic invoice fixture"

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{content_base64: Base.encode64(payload)})
    end)

    args = %{"message_id" => message.id, "attachment_id" => "part-1", "folder_name" => "Invoices"}
    assert {:ok, exported} = AgentTools.call(c.context, "save_attachment", args)
    refute exported.reused
    assert exported.size_bytes == byte_size(payload)
    assert exported.sha256 == Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
    assert_receive {:stored, "PUT", path, ^payload, headers}
    assert String.starts_with?(path, "/fixture-bucket/workspaces/#{c.workspace.id}/drive/")
    assert {"content-type", "application/pdf"} in headers
    file = Repo.get!(DriveItem, exported.file_id)
    assert file.linked_task_id == c.task.id
    assert file.created_by_agent_id == c.agent.id
    assert file.is_ai_readable
    assert file.metadata["mail_message_id"] == message.id
    assert file.metadata["mail_account_id"] == c.account.id
    assert {:ok, again} = AgentTools.call(c.context, "save_attachment", args)
    assert again.reused
    assert again.file_id == exported.file_id
    refute_receive {:stored, "PUT", _, _, _}

    assert Repo.aggregate(
             from(d in DriveItem,
               where: d.workspace_id == ^c.workspace.id and d.name == "Invoices"
             ),
             :count
           ) == 1
  end

  test "export rejects cross-workspace or restricted folders before provider access", c do
    message = attachment_message(c.account)
    {other, _} = workspace_fixture()
    {:ok, folder} = Drive.create_folder(other.id, %{"name" => "Other"})

    {:ok, restricted} =
      Drive.create_folder(c.workspace.id, %{"name" => "Restricted", "visibility" => "restricted"})

    Req.Test.stub(__MODULE__, fn _ ->
      flunk("Invalid folder must never request mailbox content")
    end)

    for id <- [folder.id, restricted.id, Ecto.UUID.generate(), "malformed"] do
      assert {:error, :invalid_mail_folder} =
               AgentTools.call(c.context, "save_attachment", %{
                 "message_id" => message.id,
                 "attachment_id" => "part-1",
                 "folder_id" => id
               })
    end

    for name <- ["../Invoices", "Invoices\n", "x/y", ""] do
      assert {:error, :invalid_mail_folder} =
               AgentTools.call(c.context, "save_attachment", %{
                 "message_id" => message.id,
                 "attachment_id" => "part-1",
                 "folder_name" => name
               })
    end
  end

  test "export rejects oversized and nonmanifest attachments without any upload", c do
    message =
      attachment_message(c.account, %{
        "attachments" => [%{"id" => "huge", "filename" => "huge.pdf", "size" => 21 * 1024 * 1024}]
      })

    Req.Test.stub(__MODULE__, fn _ -> flunk("Invalid attachment must not fetch bytes") end)

    assert {:error, :attachment_too_large} =
             AgentTools.call(c.context, "save_attachment", %{
               "message_id" => message.id,
               "attachment_id" => "huge"
             })

    assert {:error, :not_found} =
             AgentTools.call(c.context, "save_attachment", %{
               "message_id" => message.id,
               "attachment_id" => "https://attacker.invalid/file"
             })

    assert Repo.aggregate(from(d in DriveItem, where: d.workspace_id == ^c.workspace.id), :count) ==
             0
  end

  test "HTML attachment is stored as inert binary with sanitized filename", c do
    storage_fixture()

    message =
      attachment_message(c.account, %{
        "attachments" => [
          %{
            "id" => "html",
            "filename" => "../bad\r\n.html",
            "size" => 10,
            "mime_type" => "text/html"
          }
        ]
      })

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{content_base64: Base.encode64("<script>alert(1)</script>")})
    end)

    assert {:ok, exported} =
             AgentTools.call(c.context, "save_attachment", %{
               "message_id" => message.id,
               "attachment_id" => "html"
             })

    assert Repo.get!(DriveItem, exported.file_id).mime_type == "application/octet-stream"
    refute exported.name =~ "/"
    refute exported.name =~ "\r"
  end

  test "Drive upload permission is mandatory", c do
    role = Repo.get_by!(Mokaid.Members.Role, workspace_id: c.workspace.id, name: "Viewer")

    member =
      Repo.update!(Ecto.Changeset.change(c.member, role_id: role.id))
      |> Repo.preload(:role, force: true)

    context = %{c.context | member: member}

    assert {:error, :mail_file_permission_denied} =
             AgentTools.call(context, "save_attachment", %{
               "message_id" => Ecto.UUID.generate(),
               "attachment_id" => "a"
             })
  end

  test "permission downgrade during provider download prevents export", c do
    message = attachment_message(c.account)
    viewer = Repo.get_by!(Mokaid.Members.Role, workspace_id: c.workspace.id, name: "Viewer")

    Req.Test.stub(__MODULE__, fn conn ->
      Repo.update!(Ecto.Changeset.change(c.member, role_id: viewer.id))
      Req.Test.json(conn, %{content_base64: Base.encode64("%PDF-fixture")})
    end)

    assert {:error, :mail_file_permission_denied} =
             AgentTools.call(c.context, "save_attachment", %{
               "message_id" => message.id,
               "attachment_id" => "part-1"
             })

    assert Repo.aggregate(from(d in DriveItem, where: d.workspace_id == ^c.workspace.id), :count) ==
             0
  end

  test "revocation after object upload rolls back metadata and deletes the unpublished blob", c do
    storage_fixture()
    message = attachment_message(c.account)
    Process.put(:authorization_checks, 0)

    context = %{
      c.context
      | reauthorize: fn ->
          count = Process.get(:authorization_checks) + 1
          Process.put(:authorization_checks, count)
          if count >= 4, do: {:error, :revoked}, else: {:ok, %{}}
        end
    }

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{content_base64: Base.encode64("%PDF-fixture")})
    end)

    assert {:error, :mail_access_denied} =
             AgentTools.call(context, "save_attachment", %{
               "message_id" => message.id,
               "attachment_id" => "part-1"
             })

    assert_receive {:stored, "PUT", path, _, _}
    assert_receive {:stored, "DELETE", ^path, _, _}

    assert Repo.aggregate(from(d in DriveItem, where: d.workspace_id == ^c.workspace.id), :count) ==
             0
  end

  test "folder authorization is checked again before publishing an uploaded object", c do
    storage_fixture()
    message = attachment_message(c.account)
    {:ok, folder} = Drive.create_folder(c.workspace.id, %{"name" => "Invoices"}, c.member)
    Process.put(:folder_checks, 0)

    context = %{
      c.context
      | reauthorize: fn ->
          count = Process.get(:folder_checks) + 1
          Process.put(:folder_checks, count)
          if count == 4, do: Repo.update!(Ecto.Changeset.change(folder, visibility: "restricted"))
          {:ok, %{}}
        end
    }

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{content_base64: Base.encode64("%PDF-fixture")})
    end)

    assert {:error, :invalid_mail_folder} =
             AgentTools.call(context, "save_attachment", %{
               "message_id" => message.id,
               "attachment_id" => "part-1",
               "folder_id" => folder.id
             })

    assert_receive {:stored, "PUT", path, _, _}
    assert_receive {:stored, "DELETE", ^path, _, _}

    assert Repo.aggregate(
             from(d in DriveItem, where: d.workspace_id == ^c.workspace.id and d.kind == "file"),
             :count
           ) == 0
  end

  test "paused or error accounts stop cached reads/search/export but remain in safe inventory",
       c do
    message = attachment_message(c.account)

    for status <- ["paused", "error"] do
      Repo.update!(Ecto.Changeset.change(c.account, status: status))
      {:ok, found} = AgentTools.call(c.context, "search", %{})
      assert found.messages == []

      assert {:error, :mail_reconnect_required} =
               AgentTools.call(c.context, "search", %{"account_id" => c.account.id})

      assert {:error, :mail_reconnect_required} =
               AgentTools.call(c.context, "read", %{"message_id" => message.id})

      assert {:error, :mail_reconnect_required} =
               AgentTools.call(c.context, "save_attachment", %{
                 "message_id" => message.id,
                 "attachment_id" => "part-1"
               })

      {:ok, listed} = AgentTools.call(c.context, "list", %{})
      assert hd(listed.accounts).status == status
    end
  end

  test "OAuth disconnect or mismatched connection metadata revokes cached access without decryption",
       c do
    {account, connection} = oauth_account(c, "gmail", "bound@example.com")
    message = attachment_message(account)
    assert {:ok, _} = AgentTools.call(c.context, "read", %{"message_id" => message.id})

    for attrs <- [
          %{status: "disconnected"},
          %{status: "error"},
          %{connected_account: "other@example.com"},
          %{workspace_id: Ecto.UUID.generate()}
        ] do
      # Foreign workspace IDs need an existing FK row.
      attrs =
        if Map.has_key?(attrs, :workspace_id) do
          {workspace, _} = workspace_fixture()
          %{workspace_id: workspace.id}
        else
          attrs
        end

      changed = Repo.update!(Ecto.Changeset.change(connection, attrs))

      assert {:error, :mail_reconnect_required} =
               AgentTools.call(c.context, "read", %{"message_id" => message.id})

      {:ok, found} = AgentTools.call(c.context, "search", %{})
      assert found.messages == []

      Repo.update!(
        Ecto.Changeset.change(changed,
          status: connection.status,
          workspace_id: connection.workspace_id,
          connected_account: connection.connected_account
        )
      )
    end

    wrong =
      Repo.insert!(%IntegrationProvider{
        key: "mail-tools-wrong",
        name: "Wrong",
        category: "communication"
      })

    Repo.update!(Ecto.Changeset.change(connection, provider_id: wrong.id))

    assert {:error, :mail_reconnect_required} =
             AgentTools.call(c.context, "search", %{"account_id" => account.id})
  end

  test "OAuth disconnect during attachment download prevents any export", c do
    {account, connection} = oauth_account(c, "gmail", "midflight@example.com")

    connection =
      Repo.update!(
        Ecto.Changeset.change(connection,
          encrypted_credentials:
            Vault.encrypt(%{
              "access_token" => "synthetic-access",
              "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
            })
        )
      )

    message = attachment_message(account)

    Req.Test.stub(__MODULE__, fn conn ->
      Repo.update!(Ecto.Changeset.change(connection, status: "disconnected"))
      Req.Test.json(conn, %{content_base64: Base.encode64("%PDF-fixture")})
    end)

    assert account.connection_id == connection.id

    assert {:error, :mail_reconnect_required} =
             AgentTools.call(c.context, "save_attachment", %{
               "message_id" => message.id,
               "attachment_id" => "part-1"
             })

    assert Repo.aggregate(
             from(d in DriveItem, where: d.workspace_id == ^c.workspace.id and d.kind == "file"),
             :count
           ) == 0
  end
end
