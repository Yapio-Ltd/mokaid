defmodule Mokaid.Members.Team do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "teams" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    field :name, :string
    field :color, :string
    field :description, :string

    timestamps()
  end

  def changeset(team, attrs) do
    team
    |> cast(attrs, [:workspace_id, :name, :color, :description])
    |> validate_required([:workspace_id, :name])
    |> unique_constraint([:workspace_id, :name])
  end
end
