defmodule Mokaid.Marketplace.Listing do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @modes ~w(sale rent)
  @rent_billings ~w(subscription fixed)
  @fixed_days [7, 30, 90]
  @statuses ~w(active paused archived)

  schema "marketplace_listings" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :agent, Mokaid.Agents.Agent
    belongs_to :created_by_member, Mokaid.Members.Member, foreign_key: :created_by_member_id

    field :mode, :string
    field :rent_billing, :string
    field :fixed_days, :integer
    field :price_cents, :integer
    field :currency, :string, default: "usd"
    field :title, :string
    field :description, :string
    field :status, :string, default: "active"
    field :knowledge_item_count, :integer, default: 0
    field :agent_level_snapshot, :integer, default: 10

    timestamps()
  end

  def changeset(listing, attrs) do
    listing
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :created_by_member_id,
      :mode,
      :rent_billing,
      :fixed_days,
      :price_cents,
      :currency,
      :title,
      :description,
      :status,
      :knowledge_item_count,
      :agent_level_snapshot
    ])
    |> validate_required([:workspace_id, :agent_id, :mode, :price_cents, :status])
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:price_cents, greater_than_or_equal_to: 100)
    |> validate_rent_fields()
    |> unique_constraint(:agent_id, name: :marketplace_listings_one_open_per_agent)
  end

  def modes, do: @modes
  def rent_billings, do: @rent_billings
  def fixed_days_options, do: @fixed_days
  def statuses, do: @statuses

  defp validate_rent_fields(changeset) do
    case get_field(changeset, :mode) do
      "rent" ->
        changeset
        |> validate_required([:rent_billing])
        |> validate_inclusion(:rent_billing, @rent_billings)
        |> then(fn cs ->
          case get_field(cs, :rent_billing) do
            "fixed" ->
              cs
              |> validate_required([:fixed_days])
              |> validate_inclusion(:fixed_days, @fixed_days)

            _ ->
              put_change(cs, :fixed_days, nil)
          end
        end)

      _ ->
        changeset
        |> put_change(:rent_billing, nil)
        |> put_change(:fixed_days, nil)
    end
  end
end
