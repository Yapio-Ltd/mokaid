defmodule Mokaid.Assets3d.Asset do
  @moduledoc "Catalog entry for a 3D asset stored on S3/CDN (GLB meshes, not blobs in Postgres)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds ~w(character environment accessory furniture prop)

  schema "asset_3d" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    field :slug, :string
    field :kind, :string
    field :storage_key, :string
    field :cdn_path, :string
    field :sha256, :string
    field :byte_size, :integer, default: 0
    field :animation_clips, {:array, :string}, default: []
    field :metadata, :map, default: %{}

    timestamps()
  end

  def kinds, do: @kinds

  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :workspace_id,
      :slug,
      :kind,
      :storage_key,
      :cdn_path,
      :sha256,
      :byte_size,
      :animation_clips,
      :metadata
    ])
    |> validate_required([:slug, :kind, :storage_key, :cdn_path, :sha256])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:slug)
  end
end
