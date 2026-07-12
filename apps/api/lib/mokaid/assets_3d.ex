defmodule Mokaid.Assets3d do
  @moduledoc """
  Catalog of 3D assets (characters, environments, accessories…).

  Binary GLBs live on S3 (`mokaid-assets-3d-*`); only metadata is stored here.
  """

  import Ecto.Query

  alias Mokaid.Assets3d.Asset
  alias Mokaid.Repo

  @all_clips ~w(
    idle walking typing working thinking talking waiting blocked
    celebrating away offline reviewing learning requesting_approval
  )

  @catalog [
    %{
      "slug" => "avatar_male",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_male.fb67abfedaea.glb",
      "cdn_path" => "/assets3d/avatar_male.fb67abfedaea.glb",
      "sha256" => "fb67abfedaea32d84a10ad18575598223b3ffeebfc2fb1b00805d04464d43307",
      "byte_size" => 4_178_208,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Male character",
        "target_height_m" => 1.75,
        "source" => "fiverr + procedural bake"
      }
    },
    %{
      "slug" => "avatar_female",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_female.dbad3a7ec430.glb",
      "cdn_path" => "/assets3d/avatar_female.dbad3a7ec430.glb",
      "sha256" => "dbad3a7ec430bb9728ca5929d5271e0ace5d0c5275766ab07e847ee27a0422ee",
      "byte_size" => 575_432,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Female character",
        "target_height_m" => 1.65,
        "source" => "fiverr walking + procedural bake",
        "skeleton" => "mixamo_biped"
      }
    },
    %{
      "slug" => "avatar_finance",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_finance.9b8810aace2c.glb",
      "cdn_path" => "/assets3d/avatar_finance.9b8810aace2c.glb",
      "sha256" => "9b8810aace2cb11fa8d63c85b6d55a048f4c51d6935db173f8c9c1291b75c9e5",
      "byte_size" => 945_372,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Female finance",
        "target_height_m" => 1.65,
        "source" => "meshy biped + mapped AgentVisualState clips",
        "skeleton" => "mixamo_biped"
      }
    },
    %{
      "slug" => "avatar_corporate",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_corporate.cbbd97eecc61.glb",
      "cdn_path" => "/assets3d/avatar_corporate.cbbd97eecc61.glb",
      "sha256" => "cbbd97eecc61b97c906e54d533e295f10646310f550220a39f09f93f33b8bde0",
      "byte_size" => 660_308,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Corporate",
        "target_height_m" => 1.70,
        "source" => "meshy corporate walking + procedural bake",
        "skeleton" => "mixamo_biped"
      }
    }
  ]

  @doc "Idempotent upsert of catalog characters (safe to rerun from seeds)."
  def seed_catalog do
    Enum.each(@catalog, fn attrs ->
      case Repo.get_by(Asset, slug: attrs["slug"]) do
        nil -> %Asset{} |> Asset.changeset(attrs) |> Repo.insert!()
        asset -> asset |> Asset.changeset(attrs) |> Repo.update!()
      end
    end)

    backfill_agent_avatar_ids()
    :ok
  end

  defp backfill_agent_avatar_ids do
    case default_character() do
      %{id: id} ->
        from(a in Mokaid.Agents.Agent,
          where: is_nil(a.avatar_asset_id) or a.avatar_asset_id == ""
        )
        |> Repo.update_all(set: [avatar_asset_id: id])

      _ ->
        {0, nil}
    end
  end

  def list_assets(opts \\ []) do
    kind = Keyword.get(opts, :kind)

    Asset
    |> then(fn q -> if kind, do: where(q, [a], a.kind == ^kind), else: q end)
    |> order_by([a], asc: a.kind, asc: a.slug)
    |> Repo.all()
  end

  def get_asset(id), do: Repo.get(Asset, id)

  def get_asset_by_slug(slug), do: Repo.get_by(Asset, slug: slug)

  def default_character do
    get_asset_by_slug("avatar_male")
  end

  @doc "Absolute or relative URL for an asset, using ASSETS_CDN_URL when set."
  def resolve_url(%Asset{cdn_path: path}) do
    base =
      Application.get_env(:mokaid, :assets_cdn_url, "")
      |> to_string()
      |> String.trim_trailing("/")

    cond do
      base == "" -> path
      String.starts_with?(path, "http") -> path
      true -> base <> path
    end
  end
end
