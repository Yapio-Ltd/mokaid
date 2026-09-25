defmodule MokaidWeb.MailWebhookController do
  @moduledoc """
  Inbound push notifications for connected mailboxes.

  - Gmail: GCP Pub/Sub push envelope (from `users.watch`)
  - Microsoft: Graph change notifications (+ the validationToken handshake)

  Gmail rejects requests without the configured Google-signed push identity.
  Valid notifications are hints acknowledged with 2xx; polling covers missed pushes.
  """

  use MokaidWeb, :controller

  alias Mokaid.Mail
  alias Mokaid.Mail.Webhooks
  alias Mokaid.Mail.GmailPushAuth
  alias Mokaid.Mail.Workers.SyncWorker

  def gmail(conn, params) do
    with [authorization] <- get_req_header(conn, "authorization"),
         :ok <- GmailPushAuth.verify(authorization) do
      case Webhooks.decode_gmail_pubsub(params) do
        {:ok, %{email_address: email}} ->
          email |> Mail.find_gmail_accounts() |> Enum.each(&enqueue_sync/1)

        _ ->
          :ok
      end

      json(conn, %{status: "ok"})
    else
      _ -> conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})
    end
  end

  # Graph subscription handshake: echo the raw token as text/plain.
  def microsoft(conn, %{"validationToken" => token}) do
    text(conn, token)
  end

  def microsoft(conn, %{"value" => notifications}) when is_list(notifications) do
    expected_state = Webhooks.microsoft_client_state()

    for notification <- notifications,
        notification["clientState"] == expected_state,
        account = Mail.find_by_subscription(notification["subscriptionId"]),
        account != nil do
      enqueue_sync(account)
    end

    json(conn, %{status: "ok"})
  end

  def microsoft(conn, _params), do: json(conn, %{status: "ok"})

  defp enqueue_sync(account) do
    %{"mail_account_id" => account.id}
    |> SyncWorker.new()
    |> Oban.insert()
  end
end
