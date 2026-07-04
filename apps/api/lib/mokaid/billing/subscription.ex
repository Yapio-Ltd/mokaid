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
      :payment_method
    ])
    |> validate_required([:workspace_id])
    |> unique_constraint(:workspace_id)
  end
end
