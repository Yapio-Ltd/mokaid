defmodule Mokaid.Billing.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "subscriptions" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :plan, Mokaid.Billing.BillingPlan

    field :status, :string, default: "active"
    field :billing_cycle, :string, default: "monthly"
    field :current_period_start, :utc_datetime_usec
    field :current_period_end, :utc_datetime_usec
    field :external_customer_id, :string
    field :external_subscription_id, :string
    field :payment_method, :map, default: %{}
    field :credits_balance, :integer, default: 0
    field :monthly_credits, :integer, default: 0
    field :included_credits_remaining, :integer, default: 0
    field :credits_period_start, :utc_datetime_usec
    field :auto_recharge_enabled, :boolean, default: false
    field :auto_recharge_pack_key, :string
    field :auto_recharge_threshold, :integer, default: 0
    field :renewal_failures, :integer, default: 0
    field :last_renewal_attempt_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [
      :workspace_id,
      :plan_id,
      :status,
      :billing_cycle,
      :current_period_start,
      :current_period_end,
      :payment_method,
      :credits_balance,
      :monthly_credits,
      :included_credits_remaining,
      :credits_period_start,
      :auto_recharge_enabled,
      :auto_recharge_pack_key,
      :auto_recharge_threshold,
      :renewal_failures,
      :last_renewal_attempt_at
    ])
    |> validate_required([:workspace_id])
    |> unique_constraint(:workspace_id)
  end
end
