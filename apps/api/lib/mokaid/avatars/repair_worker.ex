defmodule Mokaid.Avatars.RepairWorker do
  @moduledoc "Upgrades an existing character in place without regeneration or credit charges."
  use Oban.Worker,
    queue: :avatars,
    max_attempts: 2,
    unique: [period: 600, fields: [:worker, :args], keys: [:generation_id], states: :incomplete]

  import Ecto.Query
  alias Mokaid.Agents.Agent
  alias Mokaid.Assets3d.Asset
  alias Mokaid.Avatars
  alias Mokaid.Avatars.{Generation, NativeCooker, PreparedAsset}
  alias Mokaid.{Realtime, Repo}

  @doc "Queue a repair from a trusted release operation; no provider request or debit is made."
  def enqueue(generation_id) do
    with {:ok, id} <- Ecto.UUID.cast(generation_id),
         %Generation{status: "ready", asset: %Asset{} = asset} = row <- load(id),
         true <- eligible?(row, asset) do
      %{generation_id: id} |> new() |> Oban.insert()
    else
      _ -> {:error, :avatar_not_ready}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"generation_id" => id}}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Generation{status: "ready", asset: %Asset{} = asset} = row <- load(id),
         true <- eligible?(row, asset) do
      if prepared?(asset) do
        :ok
      else
        # CPU rendering and immutable object writes happen outside DB locks.
        with {:ok, source} <- Avatars.storage().get_asset(asset.storage_key),
             {:ok, attrs} <- PreparedAsset.prepare(repair_input(row), source),
             {:ok, outcome} <- replace_if_current(row, attrs) do
          if outcome == :updated, do: broadcast_agents(row.workspace_id, asset.id)
          :ok
        end
      end
    else
      _ -> {:discard, :avatar_not_ready}
    end
  end

  defp load(id), do: Repo.get(Generation, id) |> Repo.preload(:asset)

  defp eligible?(row, asset),
    do: asset.workspace_id == row.workspace_id and asset.kind == "character"

  defp prepared?(asset) do
    manifest =
      asset.metadata
      |> Map.put("status", "ready")
      |> Map.put("animation_clips", asset.animation_clips)

    NativeCooker.validate_manifest(manifest) == :ok and
      nonempty?(asset.metadata["portrait_url"]) and
      nonempty?(asset.metadata["native_cdn_path"])
  end

  defp nonempty?(value), do: is_binary(value) and value != ""

  defp repair_input(row) do
    # Old provider URLs may have expired; only read our own already-stored body
    # preview. Passing nil prevents PreparedAsset from contacting the provider.
    input = row |> Map.from_struct() |> Map.put(:thumbnail_source_url, nil)
    old_thumbnail = row.asset.metadata["thumbnail_url"]

    if is_binary(old_thumbnail) and String.ends_with?(old_thumbnail, "/thumbnail.png") do
      key = String.replace_suffix(row.asset.storage_key, ".glb", ".png")

      case Avatars.storage().get_asset(key) do
        {:ok, body} -> Map.put(input, :stored_thumbnail, body)
        _ -> input
      end
    else
      input
    end
  end

  defp replace_if_current(original, attrs) do
    Repo.transaction(fn ->
      row = Repo.one(from g in Generation, where: g.id == ^original.id, lock: "FOR UPDATE")
      asset = Repo.one(from a in Asset, where: a.id == ^original.asset_id, lock: "FOR UPDATE")

      if row && asset && row.status == "ready" && row.asset_id == original.asset_id &&
           asset.storage_key == original.asset.storage_key &&
           asset.sha256 == original.asset.sha256 &&
           asset.updated_at == original.asset.updated_at do
        asset
        |> Asset.changeset(
          Map.take(attrs, [
            :storage_key,
            :cdn_path,
            :sha256,
            :byte_size,
            :animation_clips,
            :metadata
          ])
        )
        |> Repo.update!()

        row
        |> Generation.changeset(%{thumbnail_url: attrs.metadata["thumbnail_url"]})
        |> Repo.update!()

        :updated
      else
        # A concurrent repair or asset edit won. Its immutable URLs stay valid;
        # this stale result can never overwrite a newer revision.
        :superseded
      end
    end)
  end

  defp broadcast_agents(workspace_id, asset_id) do
    from(a in Agent,
      where: a.workspace_id == ^workspace_id and a.avatar_asset_id == ^asset_id,
      select: a.id
    )
    |> Repo.all()
    |> Enum.each(fn id ->
      Realtime.broadcast_workspace(workspace_id, "agent.updated", %{agent_id: id})
    end)
  end
end
