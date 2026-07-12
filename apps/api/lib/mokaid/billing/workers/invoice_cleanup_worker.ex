defmodule Mokaid.Billing.Workers.InvoiceCleanupWorker do
  @moduledoc """
  Expires pending invoices left behind by abandoned hosted checkouts, so the
  invoice list only shows meaningful entries. A late webhook can still settle
  an expired invoice (the payment did happen), it just stops cluttering the
  pending state.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  require Logger

  alias Mokaid.Billing

  @impl Oban.Worker
  def perform(_job) do
    count = Billing.expire_stale_pending_invoices()
    if count > 0, do: Logger.info("expired_pending_invoices count=#{count}")
    :ok
  end
end
