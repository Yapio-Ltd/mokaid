defmodule MokaidWeb.BillingController do
  use MokaidWeb, :controller

  alias Mokaid.Billing
  alias Mokaid.Billing.{Credits, Stripe}
  alias MokaidWeb.JSON, as: Serializer

  def overview(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.view") do
      workspace_id = workspace_id(conn)
      subscription = Billing.get_subscription(workspace_id)

      json(conn, %{
        data: %{
          subscription: subscription_json(subscription),
          usage: Billing.usage_summary(workspace_id),
          daily_usage: Billing.usage_daily_series(workspace_id),
          credits: Credits.summary(workspace_id),
          credit_transactions:
            Enum.map(Credits.recent_transactions(workspace_id), &credit_transaction_json/1)
        }
      })
    end
  end

  @doc "Turn auto-recharge on/off and configure the pack + threshold."
  def update_auto_recharge(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.manage"),
         %{} = subscription <- Billing.get_subscription(workspace_id(conn)) do
      attrs =
        %{}
        |> put_if(params, "enabled", :auto_recharge_enabled)
        |> put_if(params, "pack_key", :auto_recharge_pack_key)
        |> put_if(params, "threshold", :auto_recharge_threshold)

      {:ok, updated} =
        subscription |> Ecto.Changeset.change(attrs) |> Mokaid.Repo.update()

      json(conn, %{
        data: Credits.summary(workspace_id(conn)) |> Map.put(:subscription_id, updated.id)
      })
    end
  end

  defp put_if(attrs, params, key, field) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(attrs, field, value)
      :error -> attrs
    end
  end

  defp credit_transaction_json(txn) do
    %{
      id: txn.id,
      kind: txn.kind,
      amount: txn.amount,
      cost_cents: txn.cost_cents,
      balance_after: txn.balance_after,
      description: txn.description,
      inserted_at: txn.inserted_at
    }
  end

  def invoices(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.view") do
      invoices = Billing.list_invoices(workspace_id(conn))
      json(conn, %{data: Enum.map(invoices, &Serializer.invoice/1)})
    end
  end

  def plans(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.view") do
      plans = Billing.list_plans()

      json(conn, %{
        data:
          Enum.map(plans, fn plan ->
            %{
              key: plan.key,
              name: plan.name,
              price_cents_monthly: plan.price_cents_monthly,
              price_cents_yearly: plan.price_cents_yearly,
              limits: plan.limits,
              features: plan.features
            }
          end)
      })
    end
  end

  # Direct plan switching is only allowed for free plans (downgrades) — any
  # paid plan must go through Stripe Checkout so the payment actually
  # happens. Without configured Stripe credentials (local dev) everything
  # stays switchable so the flow remains testable.
  def change_plan(conn, %{"plan_key" => plan_key} = params) do
    cycle = if params["billing_cycle"] == "yearly", do: "yearly", else: "monthly"

    with :ok <- Permissions.authorize(current_member(conn), "billing.manage"),
         %{} = plan <- Billing.get_plan_by_key(plan_key) do
      amount = if cycle == "yearly", do: plan.price_cents_yearly, else: plan.price_cents_monthly

      if amount > 0 and Stripe.enabled?() do
        conn
        |> put_status(:payment_required)
        |> json(%{
          error: %{
            code: "payment_required",
            message: "Paid plans must be activated through checkout."
          }
        })
      else
        maybe_cancel_stripe_subscription(workspace_id(conn), amount)

        with {:ok, subscription} <- Billing.change_plan(workspace_id(conn), plan.key, cycle) do
          json(conn, %{data: subscription_json(subscription)})
        end
      end
    end
  end

  def config(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.view") do
      json(conn, %{
        data: %{
          publishable_key: Stripe.publishable_key(),
          payments_enabled: Stripe.enabled?()
        }
      })
    end
  end

  def portal(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.manage"),
         %{} = subscription <- Billing.get_subscription(workspace_id(conn)),
         true <- Stripe.stripe_customer?(subscription.external_customer_id) do
      return_url = "#{Stripe.web_base_url()}/billing"

      case Stripe.create_portal_session(subscription.external_customer_id, return_url) do
        {:ok, %{"url" => url}} ->
          json(conn, %{data: %{url: url}})

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{error: %{code: "portal_failed", message: inspect(reason)}})
      end
    else
      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{code: "no_customer", message: "No Stripe customer on this workspace."}
        })
    end
  end

  def credit_packs(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.view") do
      json(conn, %{data: Billing.list_credit_packs()})
    end
  end

  # Opens Stripe Checkout for a paid plan. Free plans switch directly;
  # Enterprise goes through sales. An existing Stripe subscription is updated
  # in place (proration). Without Stripe credentials (local dev) the plan
  # change applies immediately so the whole flow stays testable.
  def checkout(conn, %{"plan_key" => plan_key} = params) do
    cycle = if params["billing_cycle"] == "yearly", do: "yearly", else: "monthly"

    with :ok <- Permissions.authorize(current_member(conn), "billing.manage"),
         %{} = plan <- Billing.get_plan_by_key(plan_key) do
      amount =
        if cycle == "yearly", do: plan.price_cents_yearly, else: plan.price_cents_monthly

      cond do
        plan.key == "enterprise" ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{code: "contact_sales", message: "Enterprise is a custom contract."}})

        amount <= 0 or not Stripe.enabled?() ->
          maybe_cancel_stripe_subscription(workspace_id(conn), amount)

          with {:ok, subscription} <- Billing.change_plan(workspace_id(conn), plan.key, cycle) do
            json(conn, %{
              data: %{
                activated: true,
                simulated: amount > 0,
                subscription: subscription_json(subscription)
              }
            })
          end

        stripe_subscription_id(workspace_id(conn)) ->
          update_existing_subscription(conn, plan, cycle, amount)

        true ->
          open_checkout(conn, %{
            "kind" => "subscription",
            "amount_cents" => amount,
            "description" => "Mokaid #{plan.name} plan (#{cycle})",
            "plan_key" => plan.key,
            "billing_cycle" => cycle,
            "return_path" => params["return_path"],
            "line_items" => [
              %{
                "description" => "#{plan.name} plan — #{cycle}",
                "amount_cents" => amount,
                "plan_key" => plan.key,
                "billing_cycle" => cycle
              }
            ]
          })
      end
    end
  end

  # Opens Stripe Checkout for an AI credits pack (one-time Payment).
  def credits_checkout(conn, %{"pack_key" => pack_key} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.manage"),
         %{} = pack <- Billing.get_credit_pack(pack_key) do
      if Stripe.enabled?() do
        open_checkout(conn, %{
          "kind" => "credits",
          "amount_cents" => pack.price_cents,
          "description" => "Mokaid — #{pack.credits} AI credits",
          "return_path" => params["return_path"],
          "line_items" => [
            %{
              "description" => "#{pack.credits} AI credits",
              "amount_cents" => pack.price_cents,
              "credits" => pack.credits
            }
          ]
        })
      else
        Credits.add_purchased(workspace_id(conn), pack.credits,
          description: "#{pack.credits} AI credits"
        )

        json(conn, %{data: %{activated: true, simulated: true, credits: pack.credits}})
      end
    end
  end

  defp update_existing_subscription(conn, plan, cycle, amount) do
    subscription = Billing.get_subscription(workspace_id(conn))

    case Stripe.update_subscription(subscription.external_subscription_id, %{
           amount_cents: amount,
           product_name: "Mokaid #{plan.name} plan (#{cycle})",
           plan_key: plan.key,
           billing_cycle: cycle
         }) do
      {:ok, _} ->
        with {:ok, updated} <- Billing.change_plan(workspace_id(conn), plan.key, cycle) do
          json(conn, %{
            data: %{activated: true, simulated: false, subscription: subscription_json(updated)}
          })
        end

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: %{code: "stripe_update_failed", message: inspect(reason)}})
    end
  end

  defp open_checkout(conn, attrs) do
    user = current_user(conn)
    workspace_id = workspace_id(conn)
    existing = Billing.get_subscription(workspace_id)
    customer_id = existing && existing.external_customer_id

    with {:ok, invoice} <-
           Billing.create_pending_invoice(workspace_id, %{
             "kind" => attrs["kind"],
             "amount_cents" => attrs["amount_cents"],
             "line_items" => attrs["line_items"]
           }),
         {:ok, customer} <-
           Stripe.get_or_create_customer(%{
             customer_id: customer_id,
             email: user && user.email,
             name: user && user.full_name,
             workspace_id: workspace_id
           }),
         {:ok, session} <-
           Stripe.create_checkout_session(%{
             kind: attrs["kind"],
             amount_cents: attrs["amount_cents"],
             description: attrs["description"],
             invoice_id: invoice.id,
             workspace_id: workspace_id,
             customer_id: customer["id"],
             buyer_email: user && user.email,
             plan_key: attrs["plan_key"],
             billing_cycle: attrs["billing_cycle"],
             return_path: attrs["return_path"]
           }) do
      if url = session["url"] do
        json(conn, %{data: %{sale_url: url, checkout_url: url, invoice_id: invoice.id}})
      else
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: %{code: "checkout_failed", message: "Stripe returned no checkout URL."}})
      end
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: %{code: "checkout_failed", message: inspect(reason)}})
    end
  end

  defp stripe_subscription_id(workspace_id) do
    case Billing.get_subscription(workspace_id) do
      %{external_subscription_id: id} ->
        if Stripe.stripe_subscription?(id), do: id, else: nil

      _ ->
        nil
    end
  end

  defp maybe_cancel_stripe_subscription(_workspace_id, amount) when amount > 0, do: :ok

  defp maybe_cancel_stripe_subscription(workspace_id, _amount) do
    case Billing.get_subscription(workspace_id) do
      %{external_subscription_id: id} ->
        if Stripe.stripe_subscription?(id), do: Stripe.cancel_subscription(id)

      _ ->
        :ok
    end
  end

  defp subscription_json(nil), do: nil

  defp subscription_json(subscription) do
    plan = subscription.plan

    %{
      id: subscription.id,
      status: subscription.status,
      billing_cycle: subscription.billing_cycle,
      current_period_start: subscription.current_period_start,
      current_period_end: subscription.current_period_end,
      payment_method: subscription.payment_method,
      credits_balance: subscription.credits_balance,
      plan:
        plan &&
          %{
            key: plan.key,
            name: plan.name,
            price_cents_monthly: plan.price_cents_monthly,
            price_cents_yearly: plan.price_cents_yearly,
            limits: plan.limits,
            features: plan.features
          }
    }
  end
end
