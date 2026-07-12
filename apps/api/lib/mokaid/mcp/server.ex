defmodule Mokaid.MCP.Server do
  @moduledoc "Catalog entry: an installable MCP server (Figma, GitHub, Slack…)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @auth_kinds ~w(oauth2 api_key none custom)
  @categories ~w(productivity development communication crm finance cloud database ai search browser design docs storage monitoring)

  schema "mcp_servers" do
    field :key, :string
    field :name, :string
    field :category, :string
    field :description, :string
    field :logo_slug, :string
    field :logo_storage_key, :string
    field :featured, :boolean, default: false
    field :auth_kind, :string, default: "api_key"
    field :transport, :string, default: "http"
    field :server_url, :string
    field :docs_url, :string
    field :capabilities, {:array, :string}, default: []
    field :enabled, :boolean, default: true

    timestamps()
  end

  def categories, do: @categories

  def changeset(server, attrs) do
    server
    |> cast(attrs, [
      :key,
      :name,
      :category,
      :description,
      :logo_slug,
      :logo_storage_key,
      :featured,
      :auth_kind,
      :transport,
      :server_url,
      :docs_url,
      :capabilities,
      :enabled
    ])
    |> validate_required([:key, :name, :category])
    |> validate_inclusion(:auth_kind, @auth_kinds)
    |> validate_inclusion(:category, @categories)
    |> unique_constraint(:key)
  end
end
