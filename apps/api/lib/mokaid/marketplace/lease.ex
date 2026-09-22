defmodule Mokaid.Marketplace.Lease do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(active canceled expired)

  schema "marketplace_leases" do
    belongs_to :order, Mokaid.Marketplace.Order
    belongs_to :listing, Mokaid.Marketplace.Listing
    belongs_to :seller_workspace, Mokaid.Workspaces.Workspace, foreign_key: :seller_workspace_id
    belongs_to :buyer_workspace, Mokaid.Workspaces.Workspace, foreign_key: :buyer_workspace_id
    belongs_to :source_agent, Mokaid.Agents.Agent, foreign_key: :source_agent_id
    belongs_to :cloned_agent, Mokaid.Agents.Agent, foreign_key: :cloned_agent_id

    field :rent_billing, :string
    field :fixed_days, :integer
    field :status, :string, default: "active"
    field :starts_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :canceled_at, :utc_datetime_usec
    field :stripe_subscription_id, :string

    timestamps()
  end

  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :order_id,
      :listing_id,
      :seller_workspace_id,
      :buyer_workspace_id,
      :source_agent_id,
      :cloned_agent_id,
      :rent_billing,
      :fixed_days,
      :status,
      :starts_at,
      :expires_at,
      :canceled_at,
      :stripe_subscription_id
    ])
    |> validate_required([
      :order_id,
      :seller_workspace_id,
      :buyer_workspace_id,
      :rent_billing,
      :status,
      :starts_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:stripe_subscription_id)
  end
end
