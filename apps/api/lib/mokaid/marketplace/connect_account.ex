defmodule Mokaid.Marketplace.ConnectAccount do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "stripe_connect_accounts" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace

    field :stripe_account_id, :string
    field :charges_enabled, :boolean, default: false
    field :payouts_enabled, :boolean, default: false
    field :details_submitted, :boolean, default: false
    field :country, :string

    timestamps()
  end

  def changeset(account, attrs) do
    account
    |> cast(attrs, [
      :workspace_id,
      :stripe_account_id,
      :charges_enabled,
      :payouts_enabled,
      :details_submitted,
      :country
    ])
    |> validate_required([:workspace_id, :stripe_account_id])
    |> unique_constraint(:workspace_id)
    |> unique_constraint(:stripe_account_id)
  end

  def ready?(%__MODULE__{charges_enabled: true, details_submitted: true}), do: true
  def ready?(_), do: false
end
