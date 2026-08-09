defmodule MokaidWeb.MailWebhookController do
  @moduledoc """
  Inbound push notifications for connected mailboxes.

  - Gmail: GCP Pub/Sub push envelope (from `users.watch`)
  - Microsoft: Graph change notifications (+ the validationToken handshake)

  Always answers 2xx (except the Graph handshake) so providers don't enter
  retry storms; a lost notification is covered by the polling safety net.
  """

  use MokaidWeb, :controller

  alias Mokaid.Mail
  alias Mokaid.Mail.Webhooks
  alias Mokaid.Mail.Workers.SyncWorker

  require Logger

  def gmail(conn, params) do
    with {:ok, %{email_address: email}} <- Webhooks.decode_gmail_pubsub(params),
         %{} = account <- Mail.find_gmail_account(email) do
      enqueue_sync(account)
    else
      _ -> Logger.debug("gmail webhook ignored: #{inspect(Map.keys(params))}")
    end

    json(conn, %{status: "ok"})
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
