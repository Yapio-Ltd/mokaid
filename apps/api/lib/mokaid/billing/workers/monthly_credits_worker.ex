defmodule Mokaid.Billing.Workers.MonthlyCreditsWorker do
  @moduledoc """
  Refreshes the monthly credit grant of yearly subscriptions.

  Monthly plans get their grant refreshed by `roll_period` when the billing
  period renews, but a yearly period only rolls every 365 days — without this
  worker a yearly subscriber would receive a single "monthly" grant per year.
  Runs hourly; a subscription is refreshed once its `credits_period_start`
  is at least 30 days old.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  alias Mokaid.Billing
  alias Mokaid.Billing.Credits

  @impl Oban.Worker
  def perform(_job) do
    Billing.list_subscriptions_due_for_credit_refresh()
    |> Enum.each(fn subscription -> {:ok, _} = Credits.grant_monthly(subscription) end)

    :ok
  end
end
