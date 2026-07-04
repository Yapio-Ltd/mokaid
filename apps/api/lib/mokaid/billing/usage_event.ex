defmodule Mokaid.Billing.UsageEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "usage_events" do
    field :workspace_id, :binary_id
    field :actor_type, :string
    field :actor_id, :binary_id
    field :event_type, :string
    field :quantity, :decimal, default: Decimal.new(1)
    field :unit, :string
    field :cost_cents, :integer, default: 0
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :workspace_id,
      :actor_type,
      :actor_id,
      :event_type,
      :quantity,
      :unit,
      :cost_cents,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:workspace_id, :actor_type, :event_type, :unit])
    |> put_occurred_at()
  end

  defp put_occurred_at(changeset) do
    if get_field(changeset, :occurred_at),
      do: changeset,
      else: put_change(changeset, :occurred_at, DateTime.utc_now())
  end
end
