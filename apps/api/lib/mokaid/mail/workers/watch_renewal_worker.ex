defmodule Mokaid.Mail.Workers.WatchRenewalWorker do
  @moduledoc """
  Keeps push channels alive: Gmail `users.watch` expires after 7 days and
  Microsoft Graph subscriptions after ~3 days. The AI worker performs the
  actual renewal calls and reports the new expiry via its sync-state callback.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Mokaid.AI.WorkerClient
  alias Mokaid.Mail

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    Enum.each(Mail.list_accounts_needing_watch_renewal(), fn account ->
      case Mail.worker_account_payload(account) do
        {:ok, payload} ->
          WorkerClient.post("/mail/watch", %{
            "type" => "mail_watch",
            "account" => payload,
            "webhook" => webhook_config(account)
          })

        {:error, reason} ->
          Logger.warning("watch renewal skipped for #{account.id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp webhook_config(account) do
    base = MokaidWeb.Endpoint.url()

    case account.provider do
      "gmail" ->
        %{
          "pubsub_topic" => Application.get_env(:mokaid, :gmail_pubsub, [])[:topic],
          "notification_url" => "#{base}/api/webhooks/gmail"
        }

      "microsoft" ->
        %{
          "notification_url" => "#{base}/api/webhooks/microsoft",
          "client_state" => Mokaid.Mail.Webhooks.microsoft_client_state()
        }

      _ ->
        %{}
    end
  end
end
