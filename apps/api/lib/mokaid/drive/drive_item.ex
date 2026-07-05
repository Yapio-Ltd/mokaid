defmodule Mokaid.Drive.DriveItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "drive_items" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :parent, __MODULE__
    belongs_to :created_by_member, Mokaid.Members.Member
    belongs_to :created_by_agent, Mokaid.Agents.Agent
    belongs_to :last_modified_by_member, Mokaid.Members.Member
    belongs_to :last_modified_by_agent, Mokaid.Agents.Agent
    belongs_to :owner_member, Mokaid.Members.Member
    belongs_to :owner_agent, Mokaid.Agents.Agent
    belongs_to :linked_project, Mokaid.Projects.Project
    belongs_to :linked_task, Mokaid.Tasks.Task
    belongs_to :linked_agent, Mokaid.Agents.Agent

    field :kind, :string
    field :name, :string
    field :slug, :string
    field :mime_type, :string
    field :extension, :string
    field :size_bytes, :integer
    field :storage_key, :string
    field :checksum, :string
    field :linked_knowledge_item_id, :binary_id
    field :visibility, :string, default: "workspace"
    field :status, :string, default: "active"
    field :is_ai_readable, :boolean, default: false
    field :is_system_folder, :boolean, default: false
    field :tags, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :trashed_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    has_many :versions, Mokaid.Drive.DriveItemVersion
    has_many :children, __MODULE__, foreign_key: :parent_id

    timestamps()
  end

  @kinds ~w(file folder shortcut)
  @visibilities ~w(private workspace project restricted public_link)
  @statuses ~w(active archived trashed deleted)

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :workspace_id,
      :parent_id,
      :kind,
      :name,
      :mime_type,
      :extension,
      :size_bytes,
      :storage_key,
      :checksum,
      :created_by_member_id,
      :created_by_agent_id,
      :last_modified_by_member_id,
      :last_modified_by_agent_id,
      :owner_member_id,
      :owner_agent_id,
      :linked_project_id,
      :linked_task_id,
      :linked_knowledge_item_id,
      :linked_agent_id,
      :visibility,
      :status,
      :is_ai_readable,
      :is_system_folder,
      :tags,
      :metadata
    ])
    |> validate_required([:workspace_id, :kind, :name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_inclusion(:status, @statuses)
    |> validate_storage_key()
    |> put_slug()
  end

  defp validate_storage_key(changeset) do
    kind = get_field(changeset, :kind)
    storage_key = get_field(changeset, :storage_key)

    case {kind, storage_key} do
      {"file", nil} ->
        add_error(changeset, :storage_key, "is required for files")

      {"folder", key} when not is_nil(key) ->
        add_error(changeset, :storage_key, "folders cannot have storage keys")

      _ ->
        changeset
    end
  end

  defp put_slug(changeset) do
    case {get_field(changeset, :slug), get_field(changeset, :name)} do
      {nil, name} when is_binary(name) ->
        put_change(
          changeset,
          :slug,
          name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
        )

      _ ->
        changeset
    end
  end
end
