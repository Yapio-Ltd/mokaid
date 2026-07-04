defmodule Mokaid.Billing.Invoice do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "invoices" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :subscription, Mokaid.Billing.Subscription

    field :number, :string
    field :status, :string, default: "draft"
    field :amount_cents, :integer, default: 0
    field :currency, :string, default: "USD"
    field :issued_at, :utc_datetime_usec
    field :paid_at, :utc_datetime_usec
    field :line_items, {:array, :map}, default: []

    timestamps()
  end

  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :workspace_id,
      :subscription_id,
      :number,
      :status,
      :amount_cents,
      :currency,
      :issued_at,
      :paid_at,
      :line_items
    ])
    |> validate_required([:workspace_id, :number])
    |> unique_constraint([:workspace_id, :number])
  end
end
