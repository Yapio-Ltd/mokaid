defmodule Mokaid.Integrations.IntegrationProvider do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "integration_providers" do
    field :key, :string
    field :name, :string
    field :category, :string
    field :description, :string
    field :icon_slug, :string
    field :auth_kind, :string, default: "oauth2"
    field :capabilities, :map, default: %{}
    field :enabled, :boolean, default: true

    timestamps()
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [:key, :name, :category, :description, :icon_slug, :auth_kind, :capabilities, :enabled])
    |> validate_required([:key, :name, :category])
    |> unique_constraint(:key)
  end
end
