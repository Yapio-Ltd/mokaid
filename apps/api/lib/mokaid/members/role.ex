defmodule Mokaid.Members.Role do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "roles" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    field :name, :string
    field :description, :string
    field :is_system, :boolean, default: false

    many_to_many :permissions, Mokaid.Members.Permission,
      join_through: "role_permissions",
      join_keys: [role_id: :id, permission_id: :id]

    timestamps()
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:workspace_id, :name, :description, :is_system])
    |> validate_required([:name])
    |> unique_constraint([:workspace_id, :name])
  end
end
