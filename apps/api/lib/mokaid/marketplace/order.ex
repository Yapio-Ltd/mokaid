defmodule Mokaid.Marketplace.Order do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses ~w(pending paid fulfilled canceled failed)

  schema "marketplace_orders" do
    belongs_to :listing, Mokaid.Marketplace.Listing
    belongs_to :seller_workspace, Mokaid.Workspaces.Workspace, foreign_key: :seller_workspace_id
    belongs_to :buyer_workspace, Mokaid.Workspaces.Workspace, foreign_key: :buyer_workspace_id
    belongs_to :buyer_member, Mokaid.Members.Member, foreign_key: :buyer_member_id
    belongs_to :buyer_user, Mokaid.Accounts.User, foreign_key: :buyer_user_id
    belongs_to :source_agent, Mokaid.Agents.Agent, foreign_key: :source_agent_id
    belongs_to :cloned_agent, Mokaid.Agents.Agent, foreign_key: :cloned_agent_id

    field :mode, :string
    field :rent_billing, :string
    field :fixed_days, :integer
    field :amount_cents, :integer
    field :application_fee_cents, :integer, default: 0
    field :currency, :string, default: "usd"
    field :status, :string, default: "pending"
    field :stripe_checkout_session_id, :string
    field :stripe_payment_intent_id, :string
    field :stripe_subscription_id, :string
    field :stripe_customer_id, :string
    field :paid_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :listing_id,
      :seller_workspace_id,
      :buyer_workspace_id,
      :buyer_member_id,
      :buyer_user_id,
      :source_agent_id,
      :cloned_agent_id,
      :mode,
      :rent_billing,
      :fixed_days,
      :amount_cents,
      :application_fee_cents,
      :currency,
      :status,
      :stripe_checkout_session_id,
      :stripe_payment_intent_id,
      :stripe_subscription_id,
      :stripe_customer_id,
      :paid_at
    ])
    |> validate_required([
      :listing_id,
      :seller_workspace_id,
      :buyer_workspace_id,
      :source_agent_id,
      :mode,
      :amount_cents,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:stripe_checkout_session_id)
  end
end
