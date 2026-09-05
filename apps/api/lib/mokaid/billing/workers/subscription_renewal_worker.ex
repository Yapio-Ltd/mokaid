defmodule Mokaid.Billing.Workers.SubscriptionRenewalWorker do
  @moduledoc """
  Recurring billing safety net.

  Stripe Billing charges paid subscriptions; `invoice.paid` webhooks roll
  the local period. This worker only rolls free plans (and dev environments
  without Stripe) and flags paid workspaces that have no Stripe subscription.
  Runs hourly so period ends are honored within the hour.
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
