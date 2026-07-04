defmodule Mokaid.Billing.BillingPlan do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "billing_plans" do
    field :key, :string
    field :name, :string
    field :price_cents_monthly, :integer, default: 0
    field :price_cents_yearly, :integer, default: 0
    field :limits, :map, default: %{}
    field :features, {:array, :string}, default: []

    timestamps()
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:key, :name, :price_cents_monthly, :price_cents_yearly, :limits, :features])
    |> validate_required([:key, :name])
    |> unique_constraint(:key)
  end
end
