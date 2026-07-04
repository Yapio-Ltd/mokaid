defmodule Mokaid.Workspaces.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :logo_url, :string
    field :description, :string
    field :industry, :string
    field :timezone, :string, default: "UTC"
    field :date_format, :string, default: "MMM D, YYYY"
    field :time_format, :string, default: "12h"
    field :language, :string, default: "en"
    field :default_landing_page, :string, default: "dashboard"
    field :feature_toggles, :map, default: %{}
    field :usage_limits, :map, default: %{}
    field :settings, :map, default: %{}
    field :deleted_at, :utc_datetime_usec

    has_many :members, Mokaid.Members.Member
    has_many :agents, Mokaid.Agents.Agent

    timestamps()
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [
      :name,
      :slug,
      :logo_url,
      :description,
      :industry,
      :timezone,
      :date_format,
      :time_format,
      :language,
      :default_landing_page,
      :feature_toggles,
      :settings
    ])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/)
    |> unique_constraint(:slug)
  end
end
