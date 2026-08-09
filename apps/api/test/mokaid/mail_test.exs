defmodule Mokaid.MailTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Mail
  alias Mokaid.Mail.Webhooks
  alias Mokaid.Notifications.Notification

  defp workspace_with_member do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)
    {workspace, member}
  end

  describe "IMAP accounts" do
    test "creates an account with encrypted credentials and settings" do
      {workspace, member} = workspace_with_member()

      {:ok, account} =
        Mail.create_imap_account(workspace.id, member, %{
          "email_address" => "Someone@Example.com",
          "password" => "secret-app-password",
          "imap_host" => "imap.example.com",
          "imap_port" => 993
        })

      assert account.provider == "imap"
      # Address is normalized to lowercase.
      assert account.email_address == "someone@example.com"
      assert account.settings["imap_host"] == "imap.example.com"
      assert is_binary(account.encrypted_credentials)
      refute account.encrypted_credentials =~ "secret-app-password"
    end

    test "rejects a blank password" do
      {workspace, member} = workspace_with_member()

      assert {:error, changeset} =
               Mail.create_imap_account(workspace.id, member, %{
                 "email_address" => "someone@example.com",
                 "password" => "",
                 "imap_host" => "imap.example.com"
               })

      assert %{password: ["can't be blank"]} = errors_on(changeset)
    end

    test "enforces one account per workspace/provider/address" do
      {workspace, member} = workspace_with_member()

      attrs = %{
        "email_address" => "dup@example.com",
        "password" => "pw",
        "imap_host" => "imap.example.com"
      }

      assert {:ok, _} = Mail.create_imap_account(workspace.id, member, attrs)
      assert {:error, changeset} = Mail.create_imap_account(workspace.id, member, attrs)
      assert %{workspace_id: [_]} = errors_on(changeset)
    end
  end

  describe "OAuth accounts" do
    test "ensure_oauth_account upserts idempotently" do
      {workspace, member} = workspace_with_member()

      assert {:ok, account} =
               Mail.ensure_oauth_account(workspace.id, member, "gmail", "me@gmail.com", nil)

      assert {:ok, again} =
               Mail.ensure_oauth_account(workspace.id, member, "gmail", "me@gmail.com", nil)

      assert account.id == again.id
      assert [_only_one] = Mail.list_accounts(workspace.id)
    end

    test "gmail accounts are findable by address for webhooks" do
      {workspace, member} = workspace_with_member()

      {:ok, account} =
        Mail.ensure_oauth_account(workspace.id, member, "gmail", "me@gmail.com", nil)

      assert Mail.find_gmail_account("Me@Gmail.com").id == account.id
      assert Mail.find_gmail_account("other@gmail.com") == nil
    end
  end

  describe "message ingestion" do
    setup do
      {workspace, member} = workspace_with_member()

      {:ok, account} =
        Mail.create_imap_account(workspace.id, member, %{
          "email_address" => "inbox@example.com",
          "password" => "pw",
          "imap_host" => "imap.example.com"
        })

      %{workspace: workspace, member: member, account: account}
    end

    test "ingests new messages and dedupes re-syncs", %{workspace: workspace, account: account} do
      entries = [
        %{
          "provider_message_id" => "msg-1",
          "subject" => "Hello",
          "from_email" => "alice@example.com",
          "received_at" => DateTime.to_iso8601(DateTime.utc_now())
        },
        %{
          "provider_message_id" => "msg-2",
          "subject" => "World",
          "from_email" => "bob@example.com"
        }
      ]

      assert {:ok, 2} = Mail.ingest_messages(account, entries)
      # Re-ingesting the same batch must not duplicate anything.
      assert {:ok, 0} = Mail.ingest_messages(account, entries)
      assert length(Mail.list_messages(workspace.id)) == 2
    end

    test "matched rule bumps counters and notifies the owner", %{
      workspace: workspace,
      member: member,
      account: account
    } do
      {:ok, rule} =
        Mail.create_rule(workspace.id, member, %{
          "name" => "Invoices",
          "prompt" => "notify me about invoices",
          "action" => "notify"
        })

      entry = %{
        "provider_message_id" => "msg-invoice",
        "subject" => "Invoice #42",
        "from_email" => "billing@vendor.com",
        "ai_importance" => 75,
        "ai_summary" => "Invoice for June",
        "matched_rule_ids" => [rule.id]
      }

      assert {:ok, 1} = Mail.ingest_messages(account, [entry])

      updated_rule = Mail.get_rule(workspace.id, rule.id)
      assert updated_rule.matches_count == 1
      assert updated_rule.last_matched_at

      notification = Repo.one!(from n in Notification, where: n.kind == "mail_rule_matched")
      assert notification.title =~ "Invoices"
      assert notification.title =~ "Invoice #42"
    end

    test "very important mail notifies even without rules", %{account: account} do
      entry = %{
        "provider_message_id" => "msg-urgent",
        "subject" => "Server down",
        "from_email" => "alerts@example.com",
        "ai_importance" => 95
      }

      assert {:ok, 1} = Mail.ingest_messages(account, [entry])
      assert Repo.one!(from n in Notification, where: n.kind == "mail_important")
    end

    test "search and importance filters", %{workspace: workspace, account: account} do
      {:ok, _} =
        Mail.ingest_messages(account, [
          %{"provider_message_id" => "a", "subject" => "Quarterly report", "ai_importance" => 90},
          %{"provider_message_id" => "b", "subject" => "Newsletter", "ai_importance" => 10}
        ])

      assert [%{subject: "Quarterly report"}] =
               Mail.list_messages(workspace.id, min_importance: 70)

      assert [%{subject: "Newsletter"}] = Mail.list_messages(workspace.id, search: "newslet")
    end
  end

  describe "rules" do
    test "active_rules scopes to workspace and account", %{} do
      {workspace, member} = workspace_with_member()

      {:ok, account} =
        Mail.create_imap_account(workspace.id, member, %{
          "email_address" => "a@example.com",
          "password" => "pw",
          "imap_host" => "imap.example.com"
        })

      {:ok, global_rule} =
        Mail.create_rule(workspace.id, member, %{
          "name" => "Global",
          "prompt" => "anything urgent"
        })

      {:ok, scoped_rule} =
        Mail.create_rule(workspace.id, member, %{
          "name" => "Scoped",
          "prompt" => "invoices only",
          "mail_account_id" => account.id
        })

      {:ok, disabled} =
        Mail.create_rule(workspace.id, member, %{"name" => "Off", "prompt" => "irrelevant"})

      {:ok, _} = Mail.update_rule(disabled, %{"enabled" => false})

      active_ids = workspace.id |> Mail.active_rules(account.id) |> Enum.map(& &1.id)
      assert global_rule.id in active_ids
      assert scoped_rule.id in active_ids
      refute disabled.id in active_ids
    end

    test "rejects unknown actions" do
      {workspace, member} = workspace_with_member()

      assert {:error, changeset} =
               Mail.create_rule(workspace.id, member, %{
                 "name" => "Bad",
                 "prompt" => "whatever",
                 "action" => "explode"
               })

      assert %{action: [_]} = errors_on(changeset)
    end
  end

  describe "webhooks helpers" do
    test "decodes a Gmail Pub/Sub push envelope" do
      data = Base.encode64(~s({"emailAddress":"me@gmail.com","historyId":12345}))

      assert {:ok, %{email_address: "me@gmail.com", history_id: 12_345}} =
               Webhooks.decode_gmail_pubsub(%{"message" => %{"data" => data}})

      assert :error = Webhooks.decode_gmail_pubsub(%{"message" => %{"data" => "not-base64!!"}})
      assert :error = Webhooks.decode_gmail_pubsub(%{})
    end

    test "microsoft client state is stable and opaque" do
      state = Webhooks.microsoft_client_state()
      assert state == Webhooks.microsoft_client_state()
      assert String.length(state) > 20
    end
  end
end
