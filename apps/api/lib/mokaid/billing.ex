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
    monthly = plan_monthly_credits(plan)

    %Subscription{
      workspace_id: workspace_id,
      plan_id: plan.id,
      status: "active",
      billing_cycle: billing_cycle,
      current_period_start: now,
      current_period_end: DateTime.add(now, period_days, :day),
      monthly_credits: monthly,
      included_credits_remaining: max(monthly, 0),
      credits_period_start: now
    }
    |> Repo.insert()
    |> case do
      {:ok, subscription} -> {:ok, Repo.preload(subscription, :plan)}
      error -> error
    end
  end

  defp switch_subscription(subscription, plan, billing_cycle) do
    monthly = plan_monthly_credits(plan)

    # Switching plan refreshes the monthly grant to the new plan's amount.
    # Purchased balance (credits_balance) is untouched — packs never expire.
    subscription
    |> Ecto.Changeset.change(
      plan_id: plan.id,
      billing_cycle: billing_cycle || subscription.billing_cycle,
      monthly_credits: monthly,
      included_credits_remaining: max(monthly, 0),
      credits_period_start: DateTime.utc_now()
    )
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, Repo.preload(updated, :plan, force: true)}
      error -> error
    end
  end

  # Monthly credit grant lives in the plan's limits map (-1 = unlimited).
  defp plan_monthly_credits(%BillingPlan{limits: limits}) do
    case limits["credits_monthly"] do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  # Credit-metered pricing (ElevenLabs-style): each plan grants a monthly pool
  # of AI credits that resets every period, plus a hard cap on AI employees.
  # Customer-facing language is employees / credits — never tokens. -1 = unlimited.
  @plan_seeds [
    %{
      key: "free",
      name: "Free",
      price_cents_monthly: 0,
      price_cents_yearly: 0,
      limits: %{"agents" => 1, "credits_monthly" => 500, "mcp_integrations" => 0},
      features: [
        "1 AI employee",
        "500 AI credits / month",
        "Landing page generation",
        "HTML export"
      ]
    },
    %{
      key: "starter",
      name: "Starter",
      price_cents_monthly: 4_900,
      price_cents_yearly: 49_000,
      limits: %{"agents" => 3, "credits_monthly" => 5_000, "mcp_integrations" => 3},
      features: [
        "3 AI employees",
        "5,000 AI credits / month",
        "Live Preview & versions",
        "3 MCP integrations",
        "Buy extra credits anytime"
      ]
    },
    %{
      key: "professional",
      name: "Professional",
      price_cents_monthly: 14_900,
      price_cents_yearly: 149_000,
      limits: %{"agents" => 10, "credits_monthly" => 20_000, "mcp_integrations" => -1},
      features: [
        "10 AI employees",
        "20,000 AI credits / month",
        "All MCP integrations",
        "GitHub & Figma, deployment",
        "Team collaboration",
        "Auto-recharge available"
      ]
    },
    %{
      key: "business",
      name: "Business",
      price_cents_monthly: 39_900,
      price_cents_yearly: 399_000,
      limits: %{"agents" => 30, "credits_monthly" => 60_000, "mcp_integrations" => -1},
      features: [
        "30 AI employees",
        "60,000 AI credits / month",
        "Full AI team & API access",
        "Execution priority",
        "Priority support",
        "Auto-recharge available"
      ]
    },
    %{
      key: "enterprise",
      name: "Enterprise",
      price_cents_monthly: 0,
      price_cents_yearly: 0,
      limits: %{"agents" => -1, "credits_monthly" => -1, "mcp_integrations" => -1},
      features: [
        "Unlimited AI employees",
        "Unlimited AI credits",
        "SSO & private deployment",
        "SLA & custom models",
        "Dedicated support"
      ]
    }
  ]

  # AI credit packs (overage on top of plan quotas).
  @credit_packs [
    %{key: "credits_1k", credits: 1_000, price_cents: 1_900},
    %{key: "credits_5k", credits: 5_000, price_cents: 7_900},
    %{key: "credits_15k", credits: 15_000, price_cents: 19_900},
    %{key: "credits_50k", credits: 50_000, price_cents: 59_900}
  ]

  def list_credit_packs, do: @credit_packs

  def get_credit_pack(key), do: Enum.find(@credit_packs, &(&1.key == key))

  @doc "Upserts the standard plan catalog (idempotent, safe to rerun)."
  def seed_plans do
    Enum.each(@plan_seeds, fn attrs ->
      case get_plan_by_key(attrs.key) do
        nil -> Repo.insert!(struct(BillingPlan, attrs))
        plan -> plan |> Ecto.Changeset.change(Map.delete(attrs, :key)) |> Repo.update!()
      end
    end)

    # Retire catalog entries that no longer exist (only when unreferenced).
    keys = Enum.map(@plan_seeds, & &1.key)

    Repo.delete_all(
      from p in BillingPlan,
        where: p.key not in ^keys,
        where:
          p.id not in subquery(
            from s in Subscription, where: not is_nil(s.plan_id), select: s.plan_id
          )
    )

    :ok
  end

  ## ---------- Payments (PayMe hosted checkout) ----------

  def get_invoice(workspace_id, invoice_id) do
    Repo.one(from i in Invoice, where: i.workspace_id == ^workspace_id and i.id == ^invoice_id)
  end

  def get_invoice_by_id(invoice_id), do: Repo.get(Invoice, invoice_id)

  @doc "Creates the pending invoice a hosted checkout will settle."
  def create_pending_invoice(workspace_id, attrs) do
    %Invoice{}
    |> Invoice.changeset(
      Map.merge(attrs, %{
        "workspace_id" => workspace_id,
        "number" => generate_invoice_number(),
        "status" => "pending",
        "issued_at" => DateTime.utc_now()
      })
    )
    |> Repo.insert()
  end

  def attach_payment_reference(%Invoice{} = invoice, external_payment_id) do
    invoice
    |> Ecto.Changeset.change(external_payment_id: external_payment_id)
    |> Repo.update()
  end

  @doc """
  Settles a pending invoice after a successful payment and applies its
  effect: plan activation (kind "subscription") or AI credits top-up
  (kind "credits"). Idempotent — an already-paid invoice is left untouched.
  """
  def mark_invoice_paid(%Invoice{status: "paid"} = invoice, _payment_info), do: {:ok, invoice}

  def mark_invoice_paid(%Invoice{} = invoice, payment_info) do
    result =
      invoice
      |> Ecto.Changeset.change(status: "paid", paid_at: DateTime.utc_now())
      |> Repo.update()

    with {:ok, paid} <- result do
      apply_invoice_effect(paid)
      store_payment_method(paid.workspace_id, payment_info)

      Mokaid.Realtime.broadcast_workspace(paid.workspace_id, "billing.updated", %{
        invoice_id: paid.id
      })

      {:ok, paid}
    end
  end

  defp apply_invoice_effect(%Invoice{kind: "subscription"} = invoice) do
    item = List.first(invoice.line_items) || %{}
    plan_key = item["plan_key"] || item[:plan_key]
    cycle = item["billing_cycle"] || item[:billing_cycle] || "monthly"
    if plan_key, do: change_plan(invoice.workspace_id, plan_key, cycle)
  end

  defp apply_invoice_effect(%Invoice{kind: "credits"} = invoice) do
    item = List.first(invoice.line_items) || %{}
    credits = item["credits"] || item[:credits] || 0

    if credits > 0 do
      # add_purchased settles any negative balance (debt) before topping up.
      Mokaid.Billing.Credits.add_purchased(invoice.workspace_id, credits,
        description: "Credit pack purchase",
        cost_cents: invoice.amount_cents
      )
    end
  end

  defp apply_invoice_effect(_invoice), do: :ok

  @doc "Adds AI credits to the workspace balance (creates a Free sub if none)."
  def add_credits(workspace_id, credits) when is_integer(credits) and credits > 0 do
    subscription =
      get_subscription(workspace_id) ||
        case change_plan(workspace_id, "free") do
          {:ok, sub} -> sub
          _ -> nil
        end

    if subscription do
      {1, _} =
        Repo.update_all(
          from(s in Subscription, where: s.id == ^subscription.id),
          inc: [credits_balance: credits]
        )

      :ok
    else
      {:error, :no_subscription}
    end
  end

  defp store_payment_method(_workspace_id, nil), do: :ok

  defp store_payment_method(workspace_id, payment_info) do
    case get_subscription(workspace_id) do
      nil ->
        :ok

      subscription ->
        changes =
          [
            payment_method:
              Map.merge(subscription.payment_method || %{}, payment_info[:card] || %{})
          ] ++
            if payment_info[:buyer_key],
              do: [external_customer_id: payment_info[:buyer_key]],
              else: []

        subscription |> Ecto.Changeset.change(changes) |> Repo.update()
        :ok
    end
  end

  defp generate_invoice_number do
    "MK-" <>
      (DateTime.utc_now() |> Calendar.strftime("%Y%m%d")) <>
      "-" <> String.upcase(String.slice(Ecto.UUID.generate(), 0, 6))
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
