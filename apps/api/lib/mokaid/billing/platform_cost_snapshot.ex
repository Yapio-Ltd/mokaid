defmodule Mokaid.Billing.PlatformCostSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "platform_cost_snapshots" do
    field :provider, :string
    field :granularity, :string, default: "day"
    field :period_start, :utc_datetime_usec
    field :period_end, :utc_datetime_usec
    field :amount_cents, :integer, default: 0
    field :currency, :string, default: "USD"
    field :breakdown, :map, default: %{}
    field :breakdown_key, :string, default: "default"
    field :source, :string, default: "admin_api"
    field :fetched_at, :utc_datetime_usec
    field :raw_payload, :map, default: %{}

    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :provider,
      :granularity,
      :period_start,
      :period_end,
      :amount_cents,
      :currency,
      :breakdown,
      :breakdown_key,
      :source,
      :fetched_at,
      :raw_payload
    ])
    |> validate_required([
      :provider,
      :granularity,
      :period_start,
      :period_end,
      :amount_cents,
      :fetched_at
    ])
    |> validate_inclusion(:provider, ~w(openai anthropic aws internal))
    |> validate_inclusion(:granularity, ~w(hour day month))
    |> unique_constraint([:provider, :period_start, :granularity, :breakdown_key])
  end
end
