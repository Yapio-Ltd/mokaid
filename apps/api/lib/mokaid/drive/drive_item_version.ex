defmodule Mokaid.Drive.DriveItemVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "drive_item_versions" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :drive_item, Mokaid.Drive.DriveItem
    belongs_to :created_by_member, Mokaid.Members.Member
    belongs_to :created_by_agent, Mokaid.Agents.Agent

    field :version_number, :integer
    field :storage_key, :string
    field :size_bytes, :integer
    field :checksum, :string
    field :change_summary, :string
    field :metadata, :map, default: %{}

    timestamps(updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :workspace_id,
      :drive_item_id,
      :version_number,
      :storage_key,
      :size_bytes,
      :checksum,
      :created_by_member_id,
      :created_by_agent_id,
      :change_summary,
      :metadata
    ])
    |> validate_required([:workspace_id, :drive_item_id, :version_number, :storage_key])
    |> unique_constraint([:drive_item_id, :version_number])
  end
end
