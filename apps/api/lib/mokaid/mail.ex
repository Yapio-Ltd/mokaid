defmodule Mokaid.Mail do
  @moduledoc """
  Connected mailboxes, synced messages and AI analysis rules.

  Sync itself runs in the AI worker (Gmail REST / Microsoft Graph / IMAP);
  this context owns persistence, rule side effects (notifications + Resend
  alerts) and the credentials handed to the worker.
  """

  import Ecto.Query

  alias Mokaid.Integrations
  alias Mokaid.Integrations.TokenRefresher
  alias Mokaid.Mail.{Account, ConnectionSettings, Message, Rule}
  alias Mokaid.Notifications
  alias Mokaid.Realtime
  alias Mokaid.Repo
  alias Mokaid.Vault

  require Logger

  @important_threshold 85

  ## ─── Accounts ───

  def list_accounts(workspace_id) do
    Repo.all(
      from a in Account,
        where: a.workspace_id == ^workspace_id,
        order_by: [asc: a.inserted_at],
        preload: [member: :user]
    )
  end

  def get_account(workspace_id, id) do
    Repo.one(
      from a in Account,
        where: a.workspace_id == ^workspace_id and a.id == ^id,
        preload: [member: :user]
    )
  end

  def get_account_by_id(id), do: Repo.get(Account, id)

  def find_by_subscription(subscription_id) when is_binary(subscription_id) do
    Repo.one(from a in Account, where: a.subscription_id == ^subscription_id)
  end

  def find_by_subscription(_), do: nil

  def find_gmail_account(email_address) when is_binary(email_address) do
    email = String.downcase(email_address)

    Repo.one(
      from a in Account,
        where: a.provider == "gmail" and a.email_address == ^email and a.status == "active",
        limit: 1
    )
  end

  def find_gmail_account(_), do: nil

  def find_gmail_accounts(email_address) when is_binary(email_address) do
    email = String.downcase(String.trim(email_address))

    Repo.all(
      from a in Account,
        where: a.provider == "gmail" and a.email_address == ^email and a.status == "active"
    )
  end

  def find_gmail_accounts(_), do: []

  @doc "Accounts that rely on periodic polling (IMAP always; OAuth as a safety net)."
  def list_pollable_accounts do
    Repo.all(from a in Account, where: a.status in ["active", "error"])
  end

  @doc "Active OAuth accounts whose push channel (watch/subscription) expires soon."
  def list_accounts_needing_watch_renewal(within_hours \\ 24) do
    deadline = DateTime.add(DateTime.utc_now(), within_hours * 3600, :second)

    Repo.all(
      from a in Account,
        where:
          (a.status == "active" and a.provider in ["gmail", "microsoft"] and
             (is_nil(a.watch_expires_at) and is_nil(a.subscription_expires_at))) or
            a.watch_expires_at < ^deadline or a.subscription_expires_at < ^deadline
    )
  end

  @doc """
  Upserts the mailbox row after a successful Gmail/Microsoft OAuth.

  Best-effort from the OAuth callback: a failure here must not break the
  integration connection itself.
  """
  def ensure_oauth_account(workspace_id, member, provider, email_address, connection_id)
      when provider in ["gmail", "microsoft"] and is_binary(email_address) do
    attrs = %{
      "workspace_id" => workspace_id,
      "member_id" => member.id,
      "connection_id" => connection_id,
      "provider" => provider,
      "email_address" => email_address,
      "status" => "active",
      "error_message" => nil
    }

    %Account{}
    |> Account.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:member_id, :connection_id, :status, :error_message, :updated_at]},
      conflict_target: [:workspace_id, :provider, :email_address],
      returning: true
    )
    |> tap(fn
      {:ok, account} -> broadcast(workspace_id, account.id)
      _ -> :ok
    end)
  end

  def ensure_oauth_account(_workspace_id, _member, _provider, _email, _connection_id),
    do: {:error, :invalid_account}

  @doc "Validates IMAP and optional SMTP access before encrypting and saving credentials."
  def create_imap_account(workspace_id, member, attrs) do
    with {:ok, attrs} <- ConnectionSettings.normalize(attrs),
         :ok <- probe_mailbox(attrs) do
      save_imap_account(%Account{}, workspace_id, member, attrs)
    end
  end

  @doc "Reconnects a saved IMAP mailbox without deleting its messages or rules."
  def update_imap_account(%Account{provider: "imap"} = account, member, attrs) do
    with {:ok, attrs} <- ConnectionSettings.normalize(attrs),
         :ok <- same_mailbox_address(account, attrs),
         :ok <- probe_mailbox(attrs) do
      save_imap_account(account, account.workspace_id, member, attrs)
    end
  end

  def update_imap_account(_account, _member, _attrs), do: {:error, :invalid_account}

  defp same_mailbox_address(account, attrs) do
    if String.downcase(attrs["email_address"]) == account.email_address do
      :ok
    else
      {:error,
       Ecto.Changeset.add_error(
         Account.changeset(account, %{}),
         :email_address,
         "cannot be changed when reconnecting; connect this address as a new mailbox"
       )}
    end
  end

  defp probe_mailbox(attrs) do
    if Application.get_env(:mokaid, :imap_probe_enabled, true) do
      with :ok <- probe_imap(attrs), :ok <- probe_smtp(attrs), do: :ok
    else
      :ok
    end
  end

  defp probe_imap(attrs) do
    case Mokaid.Mail.ImapProbe.check(
           attrs["imap_host"],
           attrs["imap_port"],
           attrs["username"],
           attrs["password"],
           security: attrs["imap_security"]
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:imap_probe_failed, reason}}
    end
  end

  defp probe_smtp(%{"smtp_host" => host} = attrs) when is_binary(host) and host != "" do
    case Mokaid.Mail.SmtpProbe.check(
           host,
           attrs["smtp_port"],
           attrs["smtp_username"] || attrs["username"],
           attrs["smtp_password"] || attrs["password"],
           security: attrs["smtp_security"]
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:smtp_probe_failed, reason}}
    end
  end

  defp probe_smtp(_attrs), do: :ok

  defp save_imap_account(account, workspace_id, member, attrs) do
    settings = ConnectionSettings.settings(attrs)

    identity_changed? =
      account.id &&
        (account.email_address != String.downcase(attrs["email_address"]) or
           Enum.any?(~w(imap_host username), &((account.settings || %{})[&1] != settings[&1])))

    changeset =
      Account.changeset(account, %{
        "workspace_id" => workspace_id,
        "member_id" => member.id,
        "provider" => "imap",
        "email_address" => attrs["email_address"],
        "display_name" => attrs["display_name"],
        "settings" => settings,
        "status" => "active",
        "error_message" => nil,
        "sync_state" => if(identity_changed?, do: %{}, else: account.sync_state || %{})
      })
      |> Ecto.Changeset.put_change(
        :encrypted_credentials,
        Vault.encrypt(ConnectionSettings.credentials(attrs))
      )

    with {:ok, saved} <- Repo.insert_or_update(changeset) do
      broadcast(workspace_id, saved.id)
      {:ok, saved}
    end
  end

  def delete_account(%Account{} = account) do
    result =
      Repo.transaction(fn ->
        current = get_account(account.workspace_id, account.id)
        if is_nil(current), do: Repo.rollback(:not_found)

        # OAuth reconnect also locks its integration before upserting the mailbox.
        # Keep that order here so reconnect cannot race credential removal.
        connection_id = current.connection_id
        connection = lock_mail_connection(current)

        current =
          Repo.one(
            from a in Account,
              where: a.id == ^account.id and a.workspace_id == ^account.workspace_id,
              lock: "FOR UPDATE"
          )

        if is_nil(current), do: Repo.rollback(:not_found)

        if current.connection_id != connection_id,
          do: Repo.rollback(:account_changed)

        with {:ok, deleted} <- Repo.delete(current),
             :ok <- disconnect_unused_mail_connection(connection, current) do
          deleted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, deleted} <- result do
      broadcast(deleted.workspace_id, deleted.id)
      {:ok, deleted}
    end
  end

  defp lock_mail_connection(%Account{provider: provider, connection_id: id} = account)
       when provider in ["gmail", "microsoft"] and not is_nil(id) do
    Repo.one(
      from c in Integrations.IntegrationConnection,
        where: c.id == ^id and c.workspace_id == ^account.workspace_id,
        lock: "FOR UPDATE"
    )
    |> Repo.preload(:provider)
  end

  defp lock_mail_connection(_), do: nil

  defp disconnect_unused_mail_connection(nil, _account), do: :ok

  defp disconnect_unused_mail_connection(connection, account) do
    provider = if account.provider == "microsoft", do: "outlook", else: "gmail"
    address = String.downcase(String.trim(connection.connected_account || ""))
    shared? = Repo.exists?(from a in Account, where: a.connection_id == ^connection.id)

    if connection.provider.key == provider and address == account.email_address and not shared? do
      case connection
           |> Ecto.Changeset.change(status: "disconnected", encrypted_credentials: nil)
           |> Repo.update() do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @doc "Worker-reported sync progress: cursors, push-channel state, errors."
  def update_sync_state(%Account{} = account, attrs) do
    account
    |> Account.changeset(Map.take(attrs, sync_state_keys()))
    |> Repo.update()
  end

  defp sync_state_keys do
    ~w(sync_state status error_message last_sync_at watch_expires_at subscription_id subscription_expires_at)
  end

  @doc """
  Everything the AI worker needs to sync one account.

  OAuth accounts get a fresh access token (refreshing when needed); IMAP
  accounts get their decrypted credentials. Returns `{:error, reason}` when
  the account cannot be synced (revoked connection, missing credentials).
  """
  def worker_account_payload(%Account{} = account) do
    with {:ok, credentials} <- account_credentials(account) do
      {:ok,
       %{
         id: account.id,
         workspace_id: account.workspace_id,
         provider: account.provider,
         email_address: account.email_address,
         settings: account.settings || %{},
         sync_state: account.sync_state || %{},
         credentials: credentials
       }}
    end
  end

  defp account_credentials(%Account{provider: "imap"} = account) do
    case Vault.decrypt_map(account.encrypted_credentials) do
      {:ok, map} -> {:ok, map}
      :error -> {:error, :no_credentials}
    end
  end

  defp account_credentials(%Account{} = account) do
    case account.connection_id &&
           Repo.get(Integrations.IntegrationConnection, account.connection_id) do
      nil ->
        {:error, :no_connection}

      connection ->
        connection = Repo.preload(connection, :provider)
        expected_provider = if account.provider == "microsoft", do: "outlook", else: "gmail"
        connected_address = String.downcase(String.trim(connection.connected_account || ""))

        if connection.workspace_id == account.workspace_id and
             connection.status == "connected" and connection.provider.key == expected_provider and
             connected_address == String.downcase(account.email_address) do
          TokenRefresher.fresh_credentials(connection)
        else
          {:error, :reconnect_required}
        end
    end
  end

  ## ─── Messages ───

  def list_messages(workspace_id, opts \\ []) do
    limit = min(Keyword.get(opts, :limit, 50), 200)

    query =
      from m in Message,
        where: m.workspace_id == ^workspace_id,
        order_by: [desc: m.received_at],
        limit: ^limit

    query =
      case Keyword.get(opts, :account_id) do
        nil -> query
        id -> from m in query, where: m.mail_account_id == ^id
      end

    query =
      case Keyword.get(opts, :min_importance) do
        nil -> query
        min -> from m in query, where: m.ai_importance >= ^min
      end

    query =
      case Keyword.get(opts, :search) do
        nil ->
          query

        term ->
          pattern = "%#{term}%"

          from m in query,
            where:
              ilike(m.subject, ^pattern) or ilike(m.from_email, ^pattern) or
                ilike(m.snippet, ^pattern)
      end

    Repo.all(query)
  end

  @doc """
  Batch upsert of worker-normalized messages, then rule/importance side
  effects for the genuinely new ones (upsert conflicts are skipped).
  """
  def ingest_messages(%Account{} = account, entries) when is_list(entries) do
    known_ids = known_provider_message_ids(account, entries)

    new_messages =
      Enum.reduce(entries, [], fn entry, acc ->
        attrs =
          entry
          |> Map.put("mail_account_id", account.id)
          |> Map.put("workspace_id", account.workspace_id)

        changeset = Message.changeset(%Message{}, attrs)

        case Repo.insert(changeset,
               on_conflict:
                 {:replace,
                  [
                    :labels,
                    :folder,
                    :ai_importance,
                    :ai_category,
                    :ai_summary,
                    :matched_rule_ids,
                    :analyzed_at,
                    :updated_at
                  ]},
               conflict_target: [:mail_account_id, :provider_message_id],
               returning: true
             ) do
          {:ok, message} ->
            if MapSet.member?(known_ids, message.provider_message_id) do
              acc
            else
              [message | acc]
            end

          {:error, changeset} ->
            Logger.warning("mail message rejected: #{inspect(changeset.errors)}")
            acc
        end
      end)
      |> Enum.reverse()

    Enum.each(new_messages, &apply_side_effects(account, &1))

    if new_messages != [] do
      broadcast(account.workspace_id, account.id)
    end

    {:ok, length(new_messages)}
  end

  # Side effects (notifications, alert emails) must fire only for messages the
  # workspace has never seen, so re-syncs are checked against the DB rather
  # than insertion timestamps.
  defp known_provider_message_ids(account, entries) do
    ids =
      entries
      |> Enum.map(&(&1["provider_message_id"] || &1[:provider_message_id]))
      |> Enum.reject(&is_nil/1)

    case ids do
      [] ->
        MapSet.new()

      ids ->
        Repo.all(
          from m in Message,
            where: m.mail_account_id == ^account.id and m.provider_message_id in ^ids,
            select: m.provider_message_id
        )
        |> MapSet.new()
    end
  end

  defp apply_side_effects(account, %Message{} = message) do
    rules =
      case message.matched_rule_ids do
        [] -> []
        ids -> Repo.all(from r in Rule, where: r.id in ^ids and r.enabled)
      end

    now = DateTime.utc_now()

    Enum.each(rules, fn rule ->
      rule |> Rule.matched_changeset(now) |> Repo.update()

      Notifications.notify_member(
        account.workspace_id,
        account.member_id,
        "mail_rule_matched",
        "#{rule.name}: #{message.subject || "(no subject)"}",
        body: notification_body(message),
        resource_type: "mail_message",
        resource_id: message.id
      )

      if rule.action == "notify_email" do
        enqueue_alert_email(account, message, rule)
      end
    end)

    if rules == [] and (message.ai_importance || 0) >= @important_threshold do
      Notifications.notify_member(
        account.workspace_id,
        account.member_id,
        "mail_important",
        "Important email: #{message.subject || "(no subject)"}",
        body: notification_body(message),
        resource_type: "mail_message",
        resource_id: message.id
      )
    end
  end

  defp notification_body(message) do
    from = message.from_name || message.from_email || "Unknown sender"
    summary = message.ai_summary || message.snippet || ""
    String.slice("From #{from} — #{summary}", 0, 500)
  end

  defp enqueue_alert_email(account, message, rule) do
    %{
      "mail_account_id" => account.id,
      "message_id" => message.id,
      "rule_id" => rule.id
    }
    |> Mokaid.Mail.Workers.AlertEmailWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("alert email enqueue failed: #{inspect(reason)}")
    end
  end

  def get_message(workspace_id, id) do
    Repo.one(from m in Message, where: m.workspace_id == ^workspace_id and m.id == ^id)
  end

  def get_message_by_id(id), do: Repo.get(Message, id)

  ## ─── Rules ───

  def list_rules(workspace_id) do
    Repo.all(
      from r in Rule,
        where: r.workspace_id == ^workspace_id,
        order_by: [asc: r.inserted_at]
    )
  end

  def active_rules(workspace_id, mail_account_id) do
    Repo.all(
      from r in Rule,
        where:
          r.workspace_id == ^workspace_id and r.enabled and
            (is_nil(r.mail_account_id) or r.mail_account_id == ^mail_account_id)
    )
  end

  def get_rule(workspace_id, id) do
    Repo.one(from r in Rule, where: r.workspace_id == ^workspace_id and r.id == ^id)
  end

  def create_rule(workspace_id, member, attrs) do
    %Rule{}
    |> Rule.changeset(
      Map.merge(attrs, %{
        "workspace_id" => workspace_id,
        "created_by_member_id" => member && member.id
      })
    )
    |> Repo.insert()
    |> tap(fn
      {:ok, _} -> broadcast(workspace_id, nil)
      _ -> :ok
    end)
  end

  def update_rule(%Rule{} = rule, attrs) do
    rule
    |> Rule.changeset(Map.put(attrs, "workspace_id", rule.workspace_id))
    |> Repo.update()
    |> tap(fn
      {:ok, _} -> broadcast(rule.workspace_id, nil)
      _ -> :ok
    end)
  end

  def delete_rule(%Rule{} = rule) do
    with {:ok, deleted} <- Repo.delete(rule) do
      broadcast(rule.workspace_id, nil)
      {:ok, deleted}
    end
  end

  defp broadcast(workspace_id, account_id) do
    Realtime.broadcast_workspace(workspace_id, "mail.updated", %{account_id: account_id})
  end
end
