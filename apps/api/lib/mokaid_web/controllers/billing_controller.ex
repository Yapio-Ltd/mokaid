defmodule MokaidWeb.BillingController do
  use MokaidWeb, :controller

  alias Mokaid.Billing
  alias MokaidWeb.JSON, as: Serializer

  def overview(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.view") do
      subscription = Billing.get_subscription(workspace_id(conn))
      usage = Billing.usage_summary(workspace_id(conn))
      daily = Billing.usage_daily_series(workspace_id(conn))

      json(conn, %{
        data: %{
          subscription: subscription_json(subscription),
          usage: usage,
          daily_usage: daily
        }
      })
    end
  end

  def invoices(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "billing.view") do
      invoices = Billing.list_invoices(workspace_id(conn))
      json(conn, %{data: Enum.map(invoices, &Serializer.invoice/1)})
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
