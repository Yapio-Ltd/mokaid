defmodule Mokaid.Members.Permission do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "permissions" do
    field :key, :string
    field :description, :string

    timestamps()
  end

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:key, :description])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
