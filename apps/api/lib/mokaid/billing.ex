defmodule Mokaid.Billing do
  @moduledoc "Plans, subscriptions, invoices and usage-based billing."

  import Ecto.Query

  require Logger

  alias Mokaid.Billing.{BillingPlan, Credits, Invoice, Subscription, Stripe, UsageEvent}
  alias Mokaid.Repo

  # Renewals are retried once a day, at most this many times, before the
  # workspace is downgraded to Free (dunning).
  @max_renewal_failures 3

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
    now = DateTime.utc_now()
    cycle = billing_cycle || subscription.billing_cycle || "monthly"
    period_days = if cycle == "yearly", do: 365, else: 30

    # Switching plan refreshes the monthly grant to the new plan's amount and
    # starts a fresh billing period (a switch happens right after a payment).
    # Purchased balance (credits_balance) is untouched — packs never expire.
    subscription
    |> Ecto.Changeset.change(
      plan_id: plan.id,
      status: "active",
      billing_cycle: cycle,
      current_period_start: now,
      current_period_end: DateTime.add(now, period_days, :day),
      monthly_credits: monthly,
      included_credits_remaining: max(monthly, 0),
      credits_period_start: now,
      renewal_failures: 0
    )
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, Repo.preload(updated, :plan, force: true)}
      error -> error
    end
  end

  @doc "The price (in cents) a plan bills for one period of the given cycle."
  def plan_amount_for_cycle(%BillingPlan{} = plan, "yearly"), do: plan.price_cents_yearly
  def plan_amount_for_cycle(%BillingPlan{} = plan, _cycle), do: plan.price_cents_monthly

  ## ---------- Recurring renewal ----------

  @doc """
  Renews a subscription whose period has ended.

  Free plans (and dev environments without Stripe) roll over without a
  charge. Paid plans billed by Stripe Billing are left alone — `invoice.paid`
  webhooks roll the period. A paid plan with no Stripe subscription is
  treated as a dunning failure.
  """
  def renew_subscription(%Subscription{} = subscription) do
    subscription = Repo.preload(subscription, :plan)
    plan = subscription.plan
    cycle = subscription.billing_cycle || "monthly"
    amount = if plan, do: plan_amount_for_cycle(plan, cycle), else: 0

    cond do
      amount <= 0 or not Stripe.enabled?() ->
        roll_period(subscription)

      Stripe.stripe_subscription?(subscription.external_subscription_id) ->
        Logger.info(
          "subscription_renewal_deferred_to_stripe workspace=#{subscription.workspace_id}"
        )

        {:ok, subscription}

      true ->
        renewal_failure(subscription, :no_payment_method)
    end
  end

  @doc "Applies a Stripe `invoice.paid` renewal (idempotent on Stripe invoice id)."
  def apply_stripe_renewal(stripe_invoice) when is_map(stripe_invoice) do
    ext_id = stripe_invoice["id"]
    sub_id = Stripe.stripe_id(stripe_invoice["subscription"])

    subscription = get_subscription_by_external_subscription_id(sub_id)

    cond do
      is_binary(ext_id) and get_invoice_by_external_payment_id(ext_id) != nil ->
        {:ok, :already_recorded}

      subscription == nil ->
        {:ignored, :unknown_subscription}

      true ->
        subscription = Repo.preload(subscription, :plan)
        plan = subscription.plan
        cycle = subscription.billing_cycle || "monthly"
        amount = stripe_invoice["amount_paid"] || 0

        create_settled_invoice(subscription.workspace_id, %{
          "kind" => "subscription",
          "amount_cents" => amount,
          "external_payment_id" => ext_id,
          "line_items" => [
            %{
              "description" => "#{plan && plan.name} plan renewal — #{cycle}",
              "amount_cents" => amount,
              "plan_key" => plan && plan.key,
              "billing_cycle" => cycle
            }
          ]
        })

        if stripe_invoice["billing_reason"] == "subscription_cycle" do
          {:ok, renewed} = roll_period(subscription)

          Mokaid.Notifications.notify_roles(
            subscription.workspace_id,
            ["Owner", "Admin"],
            "billing_renewed",
            "Your #{plan && plan.name} plan was renewed"
          )

          {:ok, renewed}
        else
          {:ok, subscription}
        end
    end
  end

  def mark_renewal_failed(%Subscription{} = subscription, reason) do
    renewal_failure(subscription, reason)
  end

  def get_subscription_by_external_subscription_id(nil), do: nil

  def get_subscription_by_external_subscription_id(id) do
    Repo.one(from s in Subscription, where: s.external_subscription_id == ^id, preload: [:plan])
  end

  def get_invoice_by_external_payment_id(nil), do: nil

  def get_invoice_by_external_payment_id(id) do
    Repo.one(from i in Invoice, where: i.external_payment_id == ^id)
  end

  @doc "Syncs local status/period from a Stripe subscription.updated event."
  def sync_stripe_subscription(object) when is_map(object) do
    case get_subscription_by_external_subscription_id(Stripe.stripe_id(object["id"])) do
      nil ->
        {:ignored, :unknown_subscription}

      subscription ->
        status = stripe_status(object["status"])
        period_end = unix_to_dt(object["current_period_end"])

        changes =
          [status: status]
          |> maybe_put_change(:current_period_end, period_end)

        {:ok, updated} =
          subscription
          |> Ecto.Changeset.change(changes)
          |> Repo.update()

        if status in ["canceled", "unpaid"] do
          cancel_stripe_subscription(object)
        else
          Mokaid.Realtime.broadcast_workspace(updated.workspace_id, "billing.updated", %{
            subscription_id: updated.id
          })

          {:ok, updated}
        end
    end
  end

  @doc "Downgrades the workspace to Free after Stripe cancels the subscription."
  def cancel_stripe_subscription(object) when is_map(object) do
    case get_subscription_by_external_subscription_id(Stripe.stripe_id(object["id"])) do
      nil ->
        {:ignored, :unknown_subscription}

      subscription ->
        subscription
        |> Ecto.Changeset.change(external_subscription_id: nil)
        |> Repo.update()

        change_plan(subscription.workspace_id, "free")
    end
  end

  defp stripe_status("past_due"), do: "past_due"
  defp stripe_status("unpaid"), do: "past_due"
  defp stripe_status("canceled"), do: "canceled"
  defp stripe_status("incomplete_expired"), do: "canceled"
  defp stripe_status(_), do: "active"

  defp unix_to_dt(ts) when is_integer(ts), do: DateTime.from_unix!(ts)
  defp unix_to_dt(_), do: nil

  defp maybe_put_change(changes, _key, nil), do: changes
  defp maybe_put_change(changes, key, value), do: Keyword.put(changes, key, value)

  defp roll_period(subscription) do
    now = DateTime.utc_now()
    period_days = if subscription.billing_cycle == "yearly", do: 365, else: 30

    {:ok, updated} =
      subscription
      |> Ecto.Changeset.change(
        status: "active",
        current_period_start: now,
        current_period_end: DateTime.add(now, period_days, :day),
        renewal_failures: 0,
        last_renewal_attempt_at: now
      )
      |> Repo.update()

    {:ok, updated} = Credits.grant_monthly(updated)

    Mokaid.Realtime.broadcast_workspace(subscription.workspace_id, "billing.updated", %{
      subscription_id: subscription.id
    })

    {:ok, updated}
  end

  defp renewal_failure(subscription, reason) do
    failures = (subscription.renewal_failures || 0) + 1

    {:ok, updated} =
      subscription
      |> Ecto.Changeset.change(
        status: "past_due",
        renewal_failures: failures,
        last_renewal_attempt_at: DateTime.utc_now()
      )
      |> Repo.update()

    if failures >= @max_renewal_failures do
      Logger.warning(
        "subscription_downgraded_after_dunning workspace=#{subscription.workspace_id}"
      )

      Mokaid.Notifications.notify_roles(
        subscription.workspace_id,
        ["Owner", "Admin"],
        "billing_downgraded",
        "Payment failed #{failures} times — your workspace was moved to the Free plan",
        body: "Update your payment method from the Billing page to restore your plan."
      )

      change_plan(subscription.workspace_id, "free")
    else
      Mokaid.Notifications.notify_roles(
        subscription.workspace_id,
        ["Owner", "Admin"],
        "billing_payment_failed",
        "We couldn't renew your plan (attempt #{failures}/#{@max_renewal_failures})",
        body:
          "Reason: #{inspect(reason)}. We'll retry tomorrow — you can also update your payment method from the Billing page."
      )

      Mokaid.Realtime.broadcast_workspace(subscription.workspace_id, "billing.updated", %{
        subscription_id: subscription.id
      })

      {:ok, updated}
    end
  end

  @doc """
  Subscriptions whose monthly credit grant is due for a refresh *inside* the
  billing period — i.e. yearly subscriptions, whose period only rolls every
  365 days but whose credits are granted monthly. Monthly cycles refresh at
  renewal (`roll_period`), so they are excluded here.
  """
  def list_subscriptions_due_for_credit_refresh(now \\ DateTime.utc_now()) do
    refresh_cutoff = DateTime.add(now, -30, :day)

    Repo.all(
      from s in Subscription,
        where: s.status == "active" and s.billing_cycle == "yearly",
        where: s.monthly_credits > 0,
        where: not is_nil(s.current_period_end) and s.current_period_end > ^now,
        where: is_nil(s.credits_period_start) or s.credits_period_start <= ^refresh_cutoff
    )
  end

  @doc "Subscriptions whose billing period has ended and are due for renewal."
  def list_subscriptions_due_for_renewal(now \\ DateTime.utc_now()) do
    retry_cutoff = DateTime.add(now, -20, :hour)

    Repo.all(
      from s in Subscription,
        where: s.status in ["active", "past_due"],
        where: not is_nil(s.current_period_end) and s.current_period_end <= ^now,
        where: is_nil(s.last_renewal_attempt_at) or s.last_renewal_attempt_at < ^retry_cutoff,
        preload: [:plan]
    )
  end

  # Monthly credit grant lives in the plan's limits map (-1 = unlimited).
  defp plan_monthly_credits(%BillingPlan{limits: limits}) do
    case limits["credits_monthly"] do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  # Credit-metered pricing: each plan grants a monthly pool of AI credits plus
  # a hard cap on active AI employees (aligned with the 9-desk office).
  # Customer-facing language is employees / credits — never tokens.
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
        "HTML export",
        "Chunk RAG knowledge"
      ]
    },
    %{
      key: "starter",
      name: "Starter",
      price_cents_monthly: 4_900,
      # ~17% off vs 12× monthly (2 months free). UI rounds the /mo equivalent.
      price_cents_yearly: 49_000,
      limits: %{
        "agents" => 3,
        "credits_monthly" => 5_000,
        # -1 = unlimited MCP; only Free is capped at 0.
        "mcp_integrations" => -1,
        "knowledge_graph" => "project"
      },
      features: [
        "3 AI employees",
        "5,000 AI credits / month",
        "Live Preview & versions",
        "Unlimited MCP integrations",
        "Project Knowledge Graph",
        "Buy extra credits anytime"
      ]
    },
    %{
      key: "team",
      name: "Team",
      price_cents_monthly: 8_900,
      price_cents_yearly: 89_000,
      limits: %{
        "agents" => 6,
        "credits_monthly" => 10_000,
        "mcp_integrations" => -1,
        "knowledge_graph" => "workspace"
      },
      features: [
        "6 AI employees",
        "10,000 AI credits / month",
        "Live Preview & versions",
        "Unlimited MCP integrations",
        "Workspace Knowledge Graph",
        "Team collaboration",
        "Auto-recharge available"
      ]
    },
    %{
      key: "professional",
      name: "Professional",
      price_cents_monthly: 14_900,
      price_cents_yearly: 149_000,
      limits: %{
        "agents" => 9,
        "credits_monthly" => 20_000,
        "mcp_integrations" => -1,
        "knowledge_graph" => "workspace"
      },
      features: [
        "9 AI employees (full office)",
        "20,000 AI credits / month",
        "Unlimited MCP integrations",
        "Workspace Knowledge Graph + path/explain",
        "GitHub & Figma, deployment",
        "Team collaboration",
        "Auto-recharge available"
      ]
    }
  ]

  @doc """
  Max active (non-archived) agents allowed for the workspace's current plan.
  Workspaces without a subscription are treated as Free (1 agent).
  """
  def agent_limit(workspace_id) do
    case get_subscription(workspace_id) do
      %{plan: %{limits: %{"agents" => n}}} when is_integer(n) and n >= 0 -> n
      %{plan: nil} -> free_agent_limit()
      nil -> free_agent_limit()
      _ -> free_agent_limit()
    end
  end

  defp free_agent_limit do
    case Enum.find(@plan_seeds, &(&1.key == "free")) do
      %{limits: %{"agents" => n}} when is_integer(n) -> n
      _ -> 1
    end
  end

  @doc """
  Max MCP server installations for the workspace's current plan
  (-1 = unlimited). Workspaces without a subscription are treated as Free.
  """
  def mcp_integration_limit(workspace_id) do
    case get_subscription(workspace_id) do
      %{plan: %{limits: %{"mcp_integrations" => n}}} when is_integer(n) -> n
      _ -> free_mcp_limit()
    end
  end

  defp free_mcp_limit do
    case Enum.find(@plan_seeds, &(&1.key == "free")) do
      %{limits: %{"mcp_integrations" => n}} when is_integer(n) -> n
      _ -> 0
    end
  end

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

  ## ---------- Payments (Stripe Checkout) ----------

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
  Records an already-settled payment (renewals, auto-recharge) as a paid
  invoice, so every charge stays traceable in the invoice history.
  """
  def create_settled_invoice(workspace_id, attrs) do
    now = DateTime.utc_now()

    %Invoice{}
    |> Invoice.changeset(
      Map.merge(attrs, %{
        "workspace_id" => workspace_id,
        "number" => generate_invoice_number(),
        "status" => "paid",
        "issued_at" => now,
        "paid_at" => now
      })
    )
    |> Repo.insert()
  end

  @doc """
  Expires pending invoices whose hosted checkout was abandoned. A pending
  invoice older than `hours` (default 24) can no longer be settled by the
  webhook and is marked `expired`.
  """
  def expire_stale_pending_invoices(hours \\ 24) do
    cutoff = DateTime.add(DateTime.utc_now(), -hours, :hour)

    {count, _} =
      Repo.update_all(
        from(i in Invoice, where: i.status == "pending" and i.issued_at < ^cutoff),
        set: [status: "expired", updated_at: DateTime.utc_now()]
      )

    count
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
        card = payment_info[:card] || %{}

        changes =
          []
          |> maybe_merge_card(subscription, card)
          |> maybe_put_change(:external_customer_id, payment_info[:buyer_key])
          |> maybe_put_change(:external_subscription_id, payment_info[:subscription_id])

        if changes != [] do
          subscription |> Ecto.Changeset.change(changes) |> Repo.update()
        end

        :ok
    end
  end

  defp maybe_merge_card(changes, _subscription, card) when card == %{}, do: changes

  defp maybe_merge_card(changes, subscription, card) do
    Keyword.put(
      changes,
      :payment_method,
      Map.merge(subscription.payment_method || %{}, card)
    )
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
