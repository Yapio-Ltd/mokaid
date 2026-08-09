defmodule MokaidWeb.MailWorkerController do
  @moduledoc """
  Mail sync callbacks from the AI worker: normalized message batches, sync
  cursor updates and on-demand fresh credentials (OAuth tokens expire
  mid-sync on large mailboxes).
  """

  use MokaidWeb, :controller

  alias Mokaid.Mail

  def ingest_messages(conn, %{"id" => account_id, "messages" => messages})
      when is_list(messages) do
    case Mail.get_account_by_id(account_id) do
      nil ->
        account_not_found(conn)

      account ->
        {:ok, count} = Mail.ingest_messages(account, messages)
        json(conn, %{data: %{ingested: count}})
    end
  end

  def update_sync_state(conn, %{"id" => account_id} = params) do
    with account when not is_nil(account) <- Mail.get_account_by_id(account_id),
         {:ok, updated} <- Mail.update_sync_state(account, params) do
      json(conn, %{data: %{status: updated.status}})
    else
      nil -> account_not_found(conn)
      other -> other
    end
  end

  def credentials(conn, %{"id" => account_id}) do
    with account when not is_nil(account) <- Mail.get_account_by_id(account_id),
         {:ok, payload} <- Mail.worker_account_payload(account) do
      json(conn, %{data: payload})
    else
      nil ->
        account_not_found(conn)

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "credentials_unavailable", message: inspect(reason)}})
    end
  end

  def rules(conn, %{"id" => account_id}) do
    with account when not is_nil(account) <- Mail.get_account_by_id(account_id) do
      rules =
        account.workspace_id
        |> Mail.active_rules(account.id)
        |> Enum.map(&%{id: &1.id, name: &1.name, prompt: &1.prompt})

      json(conn, %{data: rules})
    else
      nil -> account_not_found(conn)
    end
  end

  defp account_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Mail account not found"}})
  end
end
