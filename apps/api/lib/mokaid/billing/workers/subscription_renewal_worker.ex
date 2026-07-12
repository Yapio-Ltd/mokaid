defmodule Mokaid.Billing.Workers.SubscriptionRenewalWorker do
  @moduledoc """
  Recurring billing: renews every subscription whose period has ended.

  Paid plans are charged on the stored PayMe payment method (buyer key) and
  get a paid invoice; free plans (and dev environments without PayMe) simply
  roll over. Failed charges follow the dunning flow in
  `Mokaid.Billing.renew_subscription/1` — daily retries, then downgrade to
  Free. Runs hourly so period ends are honored within the hour.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  require Logger

  alias Mokaid.Billing

  @impl Oban.Worker
  def perform(_job) do
    due = Billing.list_subscriptions_due_for_renewal()

    Enum.each(due, fn subscription ->
      case Billing.renew_subscription(subscription) do
        {:ok, _} ->
          :ok

        other ->
          Logger.warning(
            "subscription_renewal_error workspace=#{subscription.workspace_id} result=#{inspect(other)}"
          )
      end
    end)

    :ok
  end
end
