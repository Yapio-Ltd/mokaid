defmodule Mokaid.Mail.Workers.SyncWorker do
  @moduledoc """
  Dispatches one mailbox sync to the AI worker.

  Triggered by push webhooks (Gmail Pub/Sub, Microsoft Graph), the polling
  cron and manual "Sync now" from the UI. Uniqueness collapses bursts of
  notifications for the same account into a single in-flight sync.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 30,
      keys: [:mail_account_id],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Mokaid.AI.WorkerClient
  alias Mokaid.Mail

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"mail_account_id" => account_id}}) do
    case Mail.get_account_by_id(account_id) do
      nil ->
        :ok

      %{status: "paused"} ->
        :ok

      account ->
        dispatch(account)
    end
  end

  defp dispatch(account) do
    case Mail.worker_account_payload(account) do
      {:ok, payload} ->
        WorkerClient.post("/mail/sync", %{
          "type" => "mail_sync",
          "account" => payload,
          "rules" => rules_payload(account)
        })

      {:error, reason} ->
        Logger.warning("mail sync skipped for #{account.id}: #{inspect(reason)}")

        Mail.update_sync_state(account, %{
          "status" => "error",
          "error_message" => "credentials unavailable (#{inspect(reason)})"
        })

        :ok
    end
  end

  defp rules_payload(account) do
    account.workspace_id
    |> Mail.active_rules(account.id)
    |> Enum.map(&%{"id" => &1.id, "name" => &1.name, "prompt" => &1.prompt})
  end
end
