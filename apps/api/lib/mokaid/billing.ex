defmodule Mokaid.Billing do
  @moduledoc "Plans, subscriptions, invoices and usage-based billing."

  import Ecto.Query

  alias Mokaid.Billing.{BillingPlan, Invoice, Subscription, UsageEvent}
  alias Mokaid.Repo

  def get_subscription(workspace_id) do
    Repo.one(
      from s in Subscription,
        where: s.workspace_id == ^workspace_id,
        preload: [:plan]
    )
  end

  def list_invoices(workspace_id) do
    Repo.all(
      from i in Invoice,
        where: i.workspace_id == ^workspace_id,
        order_by: [desc: i.issued_at]
    )
  end

  def get_plan_by_key(key), do: Repo.get_by(BillingPlan, key: key)

  def record_usage(workspace_id, actor_type, actor_id, event_type, quantity, unit, opts \\ []) do
    %UsageEvent{}
    |> UsageEvent.changeset(%{
      "workspace_id" => workspace_id,
      "actor_type" => actor_type,
      "actor_id" => actor_id,
      "event_type" => event_type,
      "quantity" => quantity,
      "unit" => unit,
      "cost_cents" => Keyword.get(opts, :cost_cents, 0),
      "metadata" => Keyword.get(opts, :metadata, %{})
    })
    |> Repo.insert()
  end

  @doc "Aggregated usage for the current period, grouped by event type."
  def usage_summary(workspace_id, since \\ nil) do
    since = since || DateTime.add(DateTime.utc_now(), -30, :day)

    Repo.all(
      from u in UsageEvent,
        where: u.workspace_id == ^workspace_id and u.occurred_at >= ^since,
        group_by: [u.event_type, u.unit],
        select: %{
          event_type: u.event_type,
          unit: u.unit,
          total_quantity: sum(u.quantity),
          total_cost_cents: sum(u.cost_cents)
        }
    )
  end

  def usage_daily_series(workspace_id, days \\ 30) do
    since = DateTime.add(DateTime.utc_now(), -days, :day)

    Repo.all(
      from u in UsageEvent,
        where: u.workspace_id == ^workspace_id and u.occurred_at >= ^since,
        group_by: [fragment("date_trunc('day', ?)", u.occurred_at), u.event_type],
        order_by: fragment("date_trunc('day', ?)", u.occurred_at),
        select: %{
          day: fragment("date_trunc('day', ?)", u.occurred_at),
          event_type: u.event_type,
          total: sum(u.quantity)
        }
    )
  end
end
