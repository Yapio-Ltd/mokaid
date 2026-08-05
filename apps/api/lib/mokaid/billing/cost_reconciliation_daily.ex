defmodule Mokaid.Billing.CostReconciliationDaily do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "cost_reconciliation_daily" do
    field :day, :date
    field :provider, :string
    field :provider_reported_cents, :integer, default: 0
    field :internal_usage_cents, :integer, default: 0
    field :delta_cents, :integer, default: 0
    field :notes, :string

    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :day,
      :provider,
      :provider_reported_cents,
      :internal_usage_cents,
      :delta_cents,
      :notes
    ])
    |> validate_required([:day, :provider])
    |> unique_constraint([:day, :provider])
  end
end
