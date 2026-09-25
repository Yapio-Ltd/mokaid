defmodule Mokaid.Avatars.Generation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "avatar_generations" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :created_by_member, Mokaid.Members.Member
    belongs_to :asset, Mokaid.Assets3d.Asset
    field :mode, :string
    field :name, :string
    field :prompt, :string
    field :source_storage_key, :string
    field :status, :string, default: "queued"
    field :progress, :integer, default: 0
    field :task_id, :string
    field :task_kind, :string
    field :thumbnail_source_url, :string
    field :thumbnail_url, :string
    field :error, :string
    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :workspace_id,
      :created_by_member_id,
      :asset_id,
      :mode,
      :name,
      :prompt,
      :source_storage_key,
      :status,
      :progress,
      :task_id,
      :task_kind,
      :thumbnail_source_url,
      :thumbnail_url,
      :error
    ])
    |> validate_required([:workspace_id, :mode, :name])
    |> validate_inclusion(:mode, ~w(image text))
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:prompt, max: 600)
    |> unique_constraint(:task_id)
  end
end
