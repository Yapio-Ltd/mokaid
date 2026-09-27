defmodule MokaidWeb.MailController do
  @moduledoc "Connected mailboxes, analyzed messages and natural-language rules."

  use MokaidWeb, :controller

  alias Mokaid.Mail
  alias Mokaid.Mail.Workers.SyncWorker
  alias MokaidWeb.JSON, as: Serializer

  plug :private_mail_response

  defp private_mail_response(conn, _opts),
    do: put_resp_header(conn, "cache-control", "private, no-store")

  ## ─── Accounts ───

  def list_accounts(conn, _params) do
    accounts = Mail.list_accounts(workspace_id(conn))

    json(conn, %{
      data: Enum.map(accounts, &Serializer.mail_account/1),
      meta: %{
        can_send: Permissions.authorize(current_member(conn), "mail.send") == :ok,
        can_manage: Permissions.authorize(current_member(conn), "mail.manage") == :ok
      }
    })
  end

  def create_imap_account(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         :ok <- allow_connection_attempt(conn),
         {:ok, account} <-
           Mail.create_imap_account(workspace_id(conn), current_member(conn), params) do
      enqueue_sync(account)

      conn
      |> put_status(:created)
      |> json(%{data: Serializer.mail_account(account)})
    else
      {:error, :mail_connection_rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{
          error: %{
            code: "rate_limited",
            message: "Too many connection attempts. Wait one minute and try again."
          }
        })

      {:error, {probe, reason}} when probe in [:imap_probe_failed, :smtp_probe_failed] ->
        connection_error(conn, probe, reason)

      other ->
        other
    end
  end

  def update_imap_account(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         :ok <- allow_connection_attempt(conn),
         %{provider: "imap"} = account <- Mail.get_account(workspace_id(conn), id),
         {:ok, updated} <- Mail.update_imap_account(account, current_member(conn), params) do
      enqueue_sync(updated)
      json(conn, %{data: Serializer.mail_account(updated)})
    else
      nil ->
        not_found(conn)

      %{provider: _} ->
        not_found(conn)

      {:error, :mail_connection_rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{
          error: %{
            code: "rate_limited",
            message: "Too many connection attempts. Wait one minute and try again."
          }
        })

      {:error, {probe, reason}} when probe in [:imap_probe_failed, :smtp_probe_failed] ->
        connection_error(conn, probe, reason)

      other ->
        other
    end
  end

  defp allow_connection_attempt(conn) do
    case Hammer.check_rate("mail-connect:#{current_member(conn).id}", 60_000, 10) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :mail_connection_rate_limited}
    end
  end

  defp connection_error(conn, probe, reason) do
    protocol = if probe == :smtp_probe_failed, do: "SMTP", else: "IMAP"

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: String.downcase(protocol) <> "_connection_failed",
        message: connection_error_message(protocol, reason)
      }
    })
  end

  defp connection_error_message(protocol, :auth_failed),
    do:
      "The #{protocol} server rejected the login. Check your username and use an app password if your provider requires one."

  defp connection_error_message(protocol, :connect_failed),
    do: "Could not reach the #{protocol} server. Check the server name and port."

  defp connection_error_message(protocol, :tls_failed),
    do:
      "The #{protocol} server's secure connection could not be verified. Check its certificate and TLS settings."

  defp connection_error_message(protocol, :starttls_unavailable),
    do: "This #{protocol} server does not accept STARTTLS. Check the security mode and port."

  defp connection_error_message(protocol, :private_host),
    do:
      "The #{protocol} server must be reachable from the internet. Local and private network addresses are not supported."

  defp connection_error_message(_protocol, :inbox_unavailable),
    do:
      "The login worked, but the server did not allow access to INBOX. Enable IMAP access for this mailbox."

  defp connection_error_message(_protocol, :auth_unsupported),
    do:
      "This SMTP server requires another authentication method. Use the provider's OAuth connection when available."

  defp connection_error_message(protocol, _),
    do: "The #{protocol} connection could not be verified. Check the settings and try again."

  def delete_account(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         account when not is_nil(account) <- Mail.get_account(workspace_id(conn), id),
         {:ok, _} <- Mail.delete_account(account) do
      json(conn, %{data: %{deleted: true}})
    else
      nil -> not_found(conn)
      other -> other
    end
  end

  def sync_account(conn, %{"id" => id}) do
    with account when not is_nil(account) <- Mail.get_account(workspace_id(conn), id) do
      enqueue_sync(account)
      json(conn, %{data: %{queued: true}})
    else
      nil -> not_found(conn)
    end
  end

  ## ─── Messages ───

  def list_messages(conn, params) do
    opts =
      [
        account_id: presence(params["account_id"]),
        search: presence(params["q"]),
        min_importance: parse_int(params["min_importance"]),
        limit: parse_int(params["limit"]) || 50,
        offset: parse_int(params["offset"]) || 0,
        folder: presence(params["folder"]),
        filter: presence(params["filter"]),
        label: presence(params["label"]),
        sort: presence(params["sort"])
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    page = Mail.page_messages(workspace_id(conn), opts)
    json(conn, %{data: Enum.map(page.messages, &Serializer.mail_message/1), meta: page.meta})
  end

  def show_message(conn, %{"id" => id}) do
    case Mail.get_message(workspace_id(conn), id) do
      nil ->
        not_found(conn)

      message ->
        {message, hydration_error} =
          case Mail.MessageActions.hydrate(message) do
            {:ok, hydrated} -> {hydrated, nil}
            {:error, reason} -> {message, to_string(reason)}
          end

        json(conn, %{
          meta: %{hydration_error: hydration_error},
          data:
            Map.merge(
              Serializer.mail_message(message),
              Map.take(message, [:body_text, :body_html, :rfc_message_id, :references])
            )
        })
    end
  end

  def list_folders(conn, params) do
    json(conn, Mail.list_folders(workspace_id(conn), presence(params["account_id"])))
  end

  def update_message(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "mail.manage"),
         message when not is_nil(message) <- Mail.get_message(workspace_id(conn), id),
         {:ok, updated} <-
           Mail.MessageActions.apply(message, params["action"], Map.get(params, "value", true)) do
      json(conn, %{data: Serializer.mail_message(updated)})
    else
      nil -> not_found(conn)
      other -> other
    end
  end

  def download_attachment(conn, %{"id" => id, "attachment_id" => attachment_id}) do
    with message when not is_nil(message) <- Mail.get_message(workspace_id(conn), id),
         {:ok, attachment} <- Mail.Attachments.download(message, attachment_id) do
      encoded = URI.encode(attachment.filename, &URI.char_unreserved?/1)

      conn
      |> put_resp_content_type(attachment.mime_type)
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"attachment\"; filename*=UTF-8''#{encoded}"
      )
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
      |> send_resp(200, attachment.bytes)
    else
      nil -> not_found(conn)
      other -> other
    end
  end

  ## ─── Rules ───

  def list_rules(conn, _params) do
    rules = Mail.list_rules(workspace_id(conn))
    json(conn, %{data: Enum.map(rules, &Serializer.mail_rule/1)})
  end

  def create_rule(conn, params) do
    with {:ok, rule} <- Mail.create_rule(workspace_id(conn), current_member(conn), params) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.mail_rule(rule)})
    end
  end

  def update_rule(conn, %{"id" => id} = params) do
    with rule when not is_nil(rule) <- Mail.get_rule(workspace_id(conn), id),
         {:ok, updated} <- Mail.update_rule(rule, Map.delete(params, "id")) do
      json(conn, %{data: Serializer.mail_rule(updated)})
    else
      nil -> not_found(conn)
      other -> other
    end
  end

  def delete_rule(conn, %{"id" => id}) do
    with rule when not is_nil(rule) <- Mail.get_rule(workspace_id(conn), id),
         {:ok, _} <- Mail.delete_rule(rule) do
      json(conn, %{data: %{deleted: true}})
    else
      nil -> not_found(conn)
      other -> other
    end
  end

  ## ─── Helpers ───

  defp enqueue_sync(account) do
    %{"mail_account_id" => account.id}
    |> SyncWorker.new()
    |> Oban.insert()
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Resource not found"}})
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
