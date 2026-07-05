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

  def list_plans do
    Repo.all(from p in BillingPlan, order_by: [asc: p.price_cents_monthly])
  end

  @doc "Switches (or creates) the workspace subscription for another plan."
  def change_plan(workspace_id, plan_key, billing_cycle \\ nil) do
    case get_plan_by_key(plan_key) do
      nil ->
        {:error, :not_found}

      plan ->
        case get_subscription(workspace_id) do
          nil -> create_subscription(workspace_id, plan, billing_cycle || "monthly")
          subscription -> switch_subscription(subscription, plan, billing_cycle)
        end
    end
  end

  defp create_subscription(workspace_id, plan, billing_cycle) do
    now = DateTime.utc_now()
    period_days = if billing_cycle == "yearly", do: 365, else: 30

    %Subscription{
      workspace_id: workspace_id,
      plan_id: plan.id,
      status: "active",
      billing_cycle: billing_cycle,
      current_period_start: now,
      current_period_end: DateTime.add(now, period_days, :day)
    }
    |> Repo.insert()
    |> case do
      {:ok, subscription} -> {:ok, Repo.preload(subscription, :plan)}
      error -> error
    end
  end

  defp switch_subscription(subscription, plan, billing_cycle) do
    subscription
    |> Ecto.Changeset.change(
      plan_id: plan.id,
      billing_cycle: billing_cycle || subscription.billing_cycle
    )
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, Repo.preload(updated, :plan, force: true)}
      error -> error
    end
  end

  @plan_seeds [
    %{
      key: "starter",
      name: "Starter",
      price_cents_monthly: 0,
      price_cents_yearly: 0,
      limits: %{
        "agents" => 3,
        "ai_requests_monthly" => 500,
        "storage_gb" => 5,
        "automations_monthly" => 100,
        "api_calls_monthly" => 10_000
      },
      features: [
        "Up to 3 agents",
        "500 AI requests / month",
        "5 GB storage",
        "Community support"
      ]
    },
    %{
      key: "pro",
      name: "Pro Plan",
      price_cents_monthly: 4_900,
      price_cents_yearly: 46_800,
      limits: %{
        "agents" => 15,
        "ai_requests_monthly" => 10_000,
        "storage_gb" => 50,
        "automations_monthly" => 1_000,
        "api_calls_monthly" => 50_000
      },
      features: [
        "Up to 15 agents",
        "10,000 AI requests / month",
        "50 GB storage",
        "1,000 automations / month",
        "Email support",
        "Analytics"
      ]
    },
    %{
      key: "business",
      name: "Business Plan",
      price_cents_monthly: 11_900,
      price_cents_yearly: 118_800,
      limits: %{
        "agents" => 50,
        "ai_requests_monthly" => 50_000,
        "storage_gb" => 100,
        "automations_monthly" => 5_000,
        "api_calls_monthly" => 200_000
      },
      features: [
        "Up to 50 agents",
        "50,000 AI requests / month",
        "100 GB storage",
        "5,000 automations / month",
        "Priority support",
        "Advanced analytics",
        "Custom integrations"
      ]
    }
  ]

  @doc "Upserts the standard plan catalog (idempotent, safe to rerun)."
  def seed_plans do
    Enum.each(@plan_seeds, fn attrs ->
      case get_plan_by_key(attrs.key) do
        nil -> Repo.insert!(struct(BillingPlan, attrs))
        plan -> plan |> Ecto.Changeset.change(Map.delete(attrs, :key)) |> Repo.update!()
      end
    end)

    :ok
  end

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
