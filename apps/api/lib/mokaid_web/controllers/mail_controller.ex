defmodule MokaidWeb.MailController do
  @moduledoc "Connected mailboxes, analyzed messages and natural-language rules."

  use MokaidWeb, :controller

  alias Mokaid.Mail
  alias Mokaid.Mail.Workers.SyncWorker
  alias MokaidWeb.JSON, as: Serializer

  ## ─── Accounts ───

  def list_accounts(conn, _params) do
    accounts = Mail.list_accounts(workspace_id(conn))
    json(conn, %{data: Enum.map(accounts, &Serializer.mail_account/1)})
  end

  def create_imap_account(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, account} <-
           Mail.create_imap_account(workspace_id(conn), current_member(conn), params) do
      enqueue_sync(account)

      conn
      |> put_status(:created)
      |> json(%{data: Serializer.mail_account(account)})
    else
      {:error, {:imap_probe_failed, reason}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "imap_connection_failed",
            message: imap_error_message(reason)
          }
        })

      other ->
        other
    end
  end

  defp imap_error_message(:auth_failed),
    do: "The IMAP server rejected the username or password."

  defp imap_error_message(:connect_failed),
    do: "Could not reach the IMAP server. Check the host and port."

  defp imap_error_message(_),
    do: "The IMAP connection could not be verified. Check the settings and try again."

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
        limit: parse_int(params["limit"]) || 50
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    messages = Mail.list_messages(workspace_id(conn), opts)
    json(conn, %{data: Enum.map(messages, &Serializer.mail_message/1)})
  end

  def show_message(conn, %{"id" => id}) do
    case Mail.get_message(workspace_id(conn), id) do
      nil ->
        not_found(conn)

      message ->
        json(conn, %{
          data: Map.put(Serializer.mail_message(message), :body_text, message.body_text)
        })
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
