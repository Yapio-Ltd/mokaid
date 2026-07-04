defmodule Mokaid.Knowledge.KnowledgeChunk do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "knowledge_chunks" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :knowledge_item, Mokaid.Knowledge.KnowledgeItem

    field :chunk_index, :integer
    field :content, :string
    field :embedding, Pgvector.Ecto.Vector
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, [:workspace_id, :knowledge_item_id, :chunk_index, :content, :embedding, :metadata])
    |> validate_required([:workspace_id, :knowledge_item_id, :chunk_index, :content])
    |> unique_constraint([:knowledge_item_id, :chunk_index])
  end
end
