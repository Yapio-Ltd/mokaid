defmodule Mokaid.Mail.Webhooks do
  @moduledoc """
  Shared helpers for inbound mail push notifications.

  Webhooks are treated as untrusted *hints*: they only ever trigger a sync
  for an account we already know. The sync itself re-authenticates against
  the provider, so a forged notification can at worst cause a redundant,
  idempotent sync.
  """

  @doc """
  Stable opaque value sent with Microsoft Graph subscriptions and verified on
  every notification (Graph echoes it back).
  """
  def microsoft_client_state do
    secret = MokaidWeb.Endpoint.config(:secret_key_base) || "dev-secret"

    :hmac
    |> :crypto.mac(:sha256, secret, "mokaid-mail-graph-webhook")
    |> Base.url_encode64(padding: false)
  end

  @doc "Decodes a Gmail Pub/Sub push envelope into `%{email_address, history_id}`."
  def decode_gmail_pubsub(%{"message" => %{"data" => data}}) when is_binary(data) do
    with {:ok, json} <- Base.decode64(data),
         {:ok, %{"emailAddress" => email} = decoded} <- Jason.decode(json) do
      {:ok, %{email_address: email, history_id: decoded["historyId"]}}
    else
      _ -> :error
    end
  end

  def decode_gmail_pubsub(_), do: :error
end
