defmodule MokaidWeb.BillingController do
  use MokaidWeb, :controller

  alias Mokaid.Billing
  alias Mokaid.Billing.{Credits, PayMe}
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

  def change_plan(conn, %{"plan_key" => plan_key} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.manage"),
         {:ok, subscription} <-
           Billing.change_plan(workspace_id(conn), plan_key, params["billing_cycle"]) do
      json(conn, %{data: subscription_json(subscription)})
    end
  end

  def credit_packs(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.view") do
      json(conn, %{data: Billing.list_credit_packs()})
    end
  end

  # Opens a PayMe hosted checkout for a paid plan. Free plans switch
  # directly; Enterprise goes through sales. Without a configured PayMe
  # seller (local dev) the plan change applies immediately so the whole
  # flow stays testable.
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

        amount <= 0 or not PayMe.enabled?() ->
          with {:ok, subscription} <- Billing.change_plan(workspace_id(conn), plan.key, cycle) do
            json(conn, %{
              data: %{
                activated: true,
                simulated: amount > 0,
                subscription: subscription_json(subscription)
              }
            })
          end

        true ->
          open_checkout(conn, %{
            "kind" => "subscription",
            "amount_cents" => amount,
            "description" => "Mokaid #{plan.name} plan (#{cycle})",
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

  # Opens a PayMe hosted checkout for an AI credits pack.
  def credits_checkout(conn, %{"pack_key" => pack_key}) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.manage"),
         %{} = pack <- Billing.get_credit_pack(pack_key) do
      if PayMe.enabled?() do
        open_checkout(conn, %{
          "kind" => "credits",
          "amount_cents" => pack.price_cents,
          "description" => "Mokaid — #{pack.credits} AI credits",
          "line_items" => [
            %{
              "description" => "#{pack.credits} AI credits",
              "amount_cents" => pack.price_cents,
              "credits" => pack.credits
            }
          ]
        })
      else
        # Dev fallback: credit immediately (settles debt first, like a real buy).
        Credits.add_purchased(workspace_id(conn), pack.credits,
          description: "#{pack.credits} AI credits"
        )

        json(conn, %{data: %{activated: true, simulated: true, credits: pack.credits}})
      end
    end
  end

  defp open_checkout(conn, attrs) do
    user = current_user(conn)

    with {:ok, invoice} <-
           Billing.create_pending_invoice(workspace_id(conn), %{
             "kind" => attrs["kind"],
             "amount_cents" => attrs["amount_cents"],
             "line_items" => attrs["line_items"]
           }),
         {:ok, sale} <-
           PayMe.generate_hosted_sale(%{
             amount_cents: attrs["amount_cents"],
             description: attrs["description"],
             transaction_id: invoice.id,
             buyer_email: user && user.email,
             buyer_name: user && user.full_name
           }) do
      Billing.attach_payment_reference(invoice, sale.payme_sale_id)
      json(conn, %{data: %{sale_url: sale.sale_url, invoice_id: invoice.id}})
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
