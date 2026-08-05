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
    sitting preparing_coffee playing_foosball
  )

  @catalog [
    %{
      "slug" => "avatar_male",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_male.342ae6ded162.glb",
      "cdn_path" => "/assets3d/avatar_male.342ae6ded162.glb",
      "sha256" => "342ae6ded162a626d97197dcd6d6dba038101de9ca235630c9bce2b08c478032",
      "byte_size" => 4_333_312,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Male character",
        "target_height_m" => 1.75,
        "source" => "fiverr + procedural bake + POI clips"
      }
    },
    %{
      "slug" => "avatar_design",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_design.d9ea67320439.glb",
      "cdn_path" => "/assets3d/avatar_design.d9ea67320439.glb",
      "sha256" => "d9ea673204395bf2a8aedc741f4e12b75522d01bc74c74279607a89e1010a067",
      "byte_size" => 479_308,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Design",
        "target_height_m" => 1.65,
        "source" => "fiverr walking + procedural bake + POI clips (Mixamo cm-scale sit)",
        "skeleton" => "mixamo_biped",
        "archetypes" => ["design"],
        "legacy_slug" => "avatar_female"
      }
    },
    %{
      "slug" => "avatar_finance",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_finance.826a68935f66.glb",
      "cdn_path" => "/assets3d/avatar_finance.826a68935f66.glb",
      "sha256" => "826a68935f663a53bcf9a3c831c91030b1e3ba4caac85486c2f6cec85d312760",
      "byte_size" => 1_184_088,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Female finance",
        "target_height_m" => 1.65,
        "source" => "meshy biped + mapped AgentVisualState clips + POI clips",
        "skeleton" => "mixamo_biped"
      }
    },
    %{
      "slug" => "avatar_corporate",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_corporate.dd078ffb0766.glb",
      "cdn_path" => "/assets3d/avatar_corporate.dd078ffb0766.glb",
      "sha256" => "dd078ffb07669c56ac27a4081ea7f7edb33d75a72c420b5aac840a4169fb0e54",
      "byte_size" => 769_388,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Corporate",
        "target_height_m" => 1.70,
        "source" => "meshy corporate walking + procedural bake + POI clips",
        "skeleton" => "mixamo_biped"
      }
    },
    %{
      "slug" => "avatar_legal",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_legal.12554af1b7e1.glb",
      "cdn_path" => "/assets3d/avatar_legal.12554af1b7e1.glb",
      "sha256" => "12554af1b7e13465d9efc1d491c37d30ba5214e7f183f33ac68032611f69150e",
      "byte_size" => 398_952,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Legal / Lawyer",
        "target_height_m" => 1.70,
        "source" => "meshy legal walking + procedural bake + POI clips",
        "skeleton" => "mixamo_biped",
        "archetypes" => ["legal"]
      }
    },
    %{
      "slug" => "avatar_research",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_research.aee3f8496ec7.glb",
      "cdn_path" => "/assets3d/avatar_research.aee3f8496ec7.glb",
      "sha256" => "aee3f8496ec7b06302ee3bc0af1dac77cf6e4ceb85c551ecb9f7615420b0eb40",
      "byte_size" => 643_720,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Research / Chercheur",
        "target_height_m" => 1.70,
        "source" => "meshy research walk/talk/run + procedural bake + POI clips",
        "skeleton" => "mixamo_biped",
        "archetypes" => ["research"]
      }
    },
    %{
      "slug" => "avatar_developer",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_developer.d9c81b448040.glb",
      "cdn_path" => "/assets3d/avatar_developer.d9c81b448040.glb",
      "sha256" => "d9c81b448040f13d37dc15aa29dea9ebb4a70caee7a17c340226c6484496b5d9",
      "byte_size" => 968_944,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Engineering / Developer",
        "target_height_m" => 1.75,
        "source" => "meshy developer walk/run + procedural bake + POI clips + rest pose",
        "skeleton" => "mixamo_biped",
        "archetypes" => ["developer", "engineering"]
      }
    }
  ]

  @archetype_avatar_slugs %{
    "legal" => "avatar_legal",
    "finance" => "avatar_finance",
    "design" => "avatar_design",
    "research" => "avatar_research",
    "developer" => "avatar_developer",
    "engineering" => "avatar_developer"
  }

  @doc "Idempotent upsert of catalog characters (safe to rerun from seeds)."
  def seed_catalog do
    migrate_legacy_slugs()

    Enum.each(@catalog, fn attrs ->
      case Repo.get_by(Asset, slug: attrs["slug"]) do
        nil -> %Asset{} |> Asset.changeset(attrs) |> Repo.insert!()
        asset -> asset |> Asset.changeset(attrs) |> Repo.update!()
      end
    end)

    backfill_agent_avatar_ids()
    :ok
  rescue
    e ->
      require Logger
      Logger.error("Assets3d.seed_catalog failed: #{Exception.format(:error, e, __STACKTRACE__)}")
      :error
  end

  # Keep agent avatar_asset_id stable when a catalog slug is renamed.
  defp migrate_legacy_slugs do
    Enum.each(@catalog, fn attrs ->
      legacy = get_in(attrs, ["metadata", "legacy_slug"])

      if is_binary(legacy) and legacy != "" do
        case Repo.get_by(Asset, slug: legacy) do
          nil -> :ok
          asset -> asset |> Asset.changeset(attrs) |> Repo.update!()
        end
      end
    end)
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

    case load_assets(kind) do
      [] ->
        if Application.get_env(:mokaid, :auto_seed_assets_3d, true) do
          # Prod self-heal: migrate() can fail to seed while still shipping schema updates.
          seed_catalog()
          load_assets(kind)
        else
          []
        end

      assets ->
        assets
    end
  end

  defp load_assets(kind) do
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

  @doc "Preferred character for an agent archetype (falls back to default male)."
  def character_for_archetype(archetype_key) when is_binary(archetype_key) do
    slug = Map.get(@archetype_avatar_slugs, archetype_key)

    cond do
      is_binary(slug) -> get_asset_by_slug(slug) || default_character()
      true -> default_character()
    end
  end

  def character_for_archetype(_), do: default_character()

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
