defmodule Mokaid.Mail.Workers.PollWorker do
  @moduledoc """
  Polling sweep for mailboxes without a live push channel.

  IMAP has no push at all, so it syncs on every sweep. Gmail/Microsoft are
  webhook-driven; polling only kicks in as a safety net when the last sync
  is stale (missed notification, expired watch).
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Mokaid.Mail
  alias Mokaid.Mail.Workers.SyncWorker

  # OAuth accounts poll only when webhooks look dead.
  @oauth_staleness_seconds 15 * 60

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    Mail.list_pollable_accounts()
    |> Enum.filter(&due?(&1, now))
    |> Enum.each(fn account ->
      %{"mail_account_id" => account.id}
      |> SyncWorker.new()
      |> Oban.insert()
    end)

    :ok
  end

  defp due?(%{provider: "imap"}, _now), do: true

  defp due?(account, now) do
    case account.last_sync_at do
      nil -> true
      last -> DateTime.diff(now, last, :second) > @oauth_staleness_seconds
    end
  end
end
