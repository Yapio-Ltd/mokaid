defmodule Mokaid.Knowledge.KnowledgeCategory do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "knowledge_categories" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    field :name, :string
    field :color, :string
    field :position, :integer, default: 0

    has_many :items, Mokaid.Knowledge.KnowledgeItem, foreign_key: :category_id

    timestamps()
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:workspace_id, :name, :color, :position])
    |> validate_required([:workspace_id, :name])
    |> unique_constraint([:workspace_id, :name])
  end
end
