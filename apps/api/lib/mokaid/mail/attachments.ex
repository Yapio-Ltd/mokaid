defmodule Mokaid.Mail.Attachments do
  @moduledoc "Downloads only attachments already bound to a workspace-owned message."
  alias Mokaid.Mail
  alias Mokaid.Mail.{Message, MessageActions, WorkerRPC}
  @max_size 20 * 1024 * 1024

  def download(%Message{} = message, id) do
    with attachment when is_map(attachment) <-
           Enum.find(message.attachments || [], &(&1["id"] == id)),
         true <-
           is_integer(attachment["size"]) and attachment["size"] >= 0 and
             attachment["size"] <= @max_size,
         {:ok, %{"content_base64" => encoded}} when is_binary(encoded) <-
           fetch_content(message, attachment),
         true <- byte_size(encoded) <= div(@max_size * 4, 3) + 4,
         {:ok, bytes} <- Base.decode64(encoded),
         true <- byte_size(bytes) <= @max_size do
      {:ok,
       %{
         bytes: bytes,
         filename: safe_filename(attachment["filename"]),
         mime_type: "application/octet-stream"
       }}
    else
      nil -> {:error, :not_found}
      false -> {:error, :attachment_too_large}
      {:error, _} = error -> error
      _ -> {:error, :mail_provider_unavailable}
    end
  end

  defp fetch_content(message, attachment) do
    if message.provider_metadata["outbox_id"] do
      case Mokaid.Mail.Composer.outgoing_attachment(
             message.workspace_id,
             message.id,
             attachment["id"]
           ) do
        {:ok, stored} ->
          {:ok, %{"content_base64" => stored[:content_base64] || stored["content_base64"]}}

        error ->
          error
      end
    else
      with account when not is_nil(account) <-
             Mail.get_account(message.workspace_id, message.mail_account_id),
           {:ok, payload} <- Mail.worker_account_payload(account) do
        WorkerRPC.post("/mail/attachment", %{
          account: payload,
          message: MessageActions.worker_message(message),
          attachment: attachment
        })
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end
  end

  def safe_filename(filename) when is_binary(filename) do
    filename
    |> String.replace(~r/[\x00-\x1f\x7f\/\\\\";]/u, "_")
    |> String.slice(0, 180)
    |> case do
      name when name in ["", ".", ".."] -> "attachment"
      name -> name
    end
  end

  def safe_filename(_), do: "attachment"
end
