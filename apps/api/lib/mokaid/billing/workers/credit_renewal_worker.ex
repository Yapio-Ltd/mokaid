defmodule Mokaid.Billing.Workers.CreditRenewalWorker do
  @moduledoc """
  Resets each active subscription's monthly credit grant when its period
  rolls over. Purchased top-up packs (credits_balance) are untouched — only
  the plan's included pool is refreshed. Runs daily; only subscriptions whose
  credit period is older than 30 days are renewed.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3

  import Ecto.Query

  alias Mokaid.Billing.{Credits, Subscription}
  alias Mokaid.Repo

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -30, :day)

    due =
      Repo.all(
        from s in Subscription,
          where:
            s.status == "active" and s.monthly_credits > 0 and
              (is_nil(s.credits_period_start) or s.credits_period_start < ^cutoff)
      )

    Enum.each(due, &Credits.grant_monthly/1)
    :ok
  end
end
