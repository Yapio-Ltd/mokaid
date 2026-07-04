defmodule Mokaid.Knowledge.KnowledgeItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "knowledge_items" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :category, Mokaid.Knowledge.KnowledgeCategory
    belongs_to :created_by_member, Mokaid.Members.Member
    belongs_to :file, Mokaid.Files.File
    belongs_to :drive_item, Mokaid.Drive.DriveItem

    field :title, :string
    field :type, :string
    field :source_url, :string
    field :body, :string
    field :status, :string, default: "draft"
    field :visibility, :string, default: "workspace"
    field :tags, {:array, :string}, default: []
    field :version, :integer, default: 1
    field :indexing_status, :string, default: "not_indexed"
    field :metadata, :map, default: %{}

    has_many :chunks, Mokaid.Knowledge.KnowledgeChunk

    timestamps()
  end

  @types ~w(document link file note)
  @statuses ~w(draft processing published archived failed)
  @visibilities ~w(workspace restricted private)

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :workspace_id,
      :category_id,
      :created_by_member_id,
      :title,
      :type,
      :source_url,
      :file_id,
      :drive_item_id,
      :body,
      :status,
      :visibility,
      :tags,
      :version,
      :indexing_status,
      :metadata
    ])
    |> validate_required([:workspace_id, :title, :type])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:visibility, @visibilities)
  end
end
