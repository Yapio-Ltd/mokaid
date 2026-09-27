defmodule Mokaid.Mail.MessageActions do
  @moduledoc "Apply provider-side message changes before updating the local view."
  alias Mokaid.{Mail, Repo, Realtime}
  alias Mokaid.Mail.{Message, WorkerRPC}

  def apply(%Message{} = message, action, value)
      when action in ~w(read star archive spam trash) and is_boolean(value) do
    with account when not is_nil(account) <-
           Mail.get_account(message.workspace_id, message.mail_account_id),
         {:ok, account_payload} <- Mail.worker_account_payload(account),
         {:ok, %{"changes" => changes}} <-
           WorkerRPC.post("/mail/message/action", %{
             account: account_payload,
             message: worker_message(message),
             action: action,
             value: value
           }),
         {:ok, updated} <-
           message
           |> Message.changeset(
             Map.take(
               changes,
               ~w(provider_message_id provider_metadata is_read is_starred labels folder)
             )
           )
           |> Repo.update() do
      Realtime.broadcast_workspace(message.workspace_id, "mail.updated", %{account_id: account.id})

      {:ok, updated}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :mail_provider_unavailable}
    end
  end

  def apply(_, _, _), do: {:error, :invalid_mail_action}

  def hydrate(%Message{} = message) do
    cond do
      message.provider_metadata["outbox_id"] ->
        {:ok, message}

      message.provider_metadata["reader_version"] == 1 ->
        {:ok, message}

      true ->
        with account when not is_nil(account) <-
               Mail.get_account(message.workspace_id, message.mail_account_id),
             {:ok, payload} <- Mail.worker_account_payload(account),
             {:ok, %{"message" => attrs}} <-
               WorkerRPC.post("/mail/message/detail", %{
                 account: payload,
                 message: worker_message(message)
               }) do
          message
          |> Message.changeset(
            Map.take(
              attrs,
              ~w(body_text body_html rfc_message_id references attachments provider_metadata is_read is_starred labels folder has_attachments)
            )
          )
          |> Repo.update()
        else
          nil -> {:error, :not_found}
          {:error, _} = error -> error
          _ -> {:error, :mail_provider_unavailable}
        end
    end
  end

  def worker_message(message) do
    Map.take(message, [
      :id,
      :workspace_id,
      :mail_account_id,
      :provider_message_id,
      :provider_metadata,
      :rfc_message_id,
      :folder,
      :labels,
      :is_read,
      :is_starred
    ])
  end
end
