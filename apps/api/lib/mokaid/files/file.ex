defmodule Mokaid.Files.File do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "files" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :uploaded_by_member, Mokaid.Members.Member
    belongs_to :uploaded_by_agent, Mokaid.Agents.Agent

    field :storage_key, :string
    field :bucket, :string
    field :file_name, :string
    field :mime_type, :string
    field :size_bytes, :integer
    field :checksum, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(file, attrs) do
    file
    |> cast(attrs, [
      :workspace_id,
      :storage_key,
      :bucket,
      :file_name,
      :mime_type,
      :size_bytes,
      :checksum,
      :uploaded_by_member_id,
      :uploaded_by_agent_id,
      :metadata
    ])
    |> validate_required([:workspace_id, :storage_key, :bucket, :file_name])
  end
end
