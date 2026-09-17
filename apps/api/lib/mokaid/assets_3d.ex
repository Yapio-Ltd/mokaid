defmodule Mokaid.Assets3d do
  @moduledoc """
  Catalog of 3D assets (characters, environments, accessories…).

  Binary GLBs live on S3 (`mokaid-assets-3d-*`); only metadata is stored here.
  """

  import Ecto.Query

  alias Mokaid.Assets3d.Asset
  alias Mokaid.Repo

  @all_clips ~w(
    idle walking typing working thinking talking
    waiting blocked celebrating away offline reviewing
    learning requesting_approval sitting sitting_sofa preparing_coffee playing_foosball
    sit_down stand_up sit_down_sofa stand_up_sofa walking_coffee carrying_coffee
    drinking_coffee talking_coffee chair_pullback chair_pushin walking_brisk walking_relaxed
    typing_focused typing_relaxed greeting laughing laughing_coffee talking_standing
    sitting_sofa_coffee talking_sofa_coffee drinking_sofa_coffee laughing_sofa_coffee sit_down_sofa_coffee stand_up_sofa_coffee
    talking_sofa_coffee_left talking_sofa_coffee_right coffee_putdown phone_pickup phone_call phone_putdown
  )

  @catalog [
    %{
      "slug" => "avatar_male",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_male.21ca01757e1a.glb",
      "cdn_path" => "/assets3d/avatar_male.21ca01757e1a.glb",
      "sha256" => "21ca01757e1a5b0242344f76391b8ca5e2ecc98f7d588d83143b0219efe0d7db",
      "byte_size" => 20_364_080,
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
      "storage_key" => "assets3d/avatar_design.1c0dba698d81.glb",
      "cdn_path" => "/assets3d/avatar_design.1c0dba698d81.glb",
      "sha256" => "1c0dba698d817f42263efdc62c82d528eef0c5840f254d246ca618bd9658960c",
      "byte_size" => 8_661_044,
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
      "storage_key" => "assets3d/avatar_finance.1db634ff8a82.glb",
      "cdn_path" => "/assets3d/avatar_finance.1db634ff8a82.glb",
      "sha256" => "1db634ff8a82cc9911aa224b25a38efde26034a389fc500a11cdae1875be6eba",
      "byte_size" => 8_594_420,
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
      "storage_key" => "assets3d/avatar_corporate.b2951a24cd02.glb",
      "cdn_path" => "/assets3d/avatar_corporate.b2951a24cd02.glb",
      "sha256" => "b2951a24cd0219ffd306353c2fd31c37aae1760ea802f4378010cb67ab1e0a0c",
      "byte_size" => 9_062_200,
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
      "storage_key" => "assets3d/avatar_legal.859687268a64.glb",
      "cdn_path" => "/assets3d/avatar_legal.859687268a64.glb",
      "sha256" => "859687268a642c7644714cee5ebd5e9f72b6a4835c62140122f3f965f3364198",
      "byte_size" => 8_633_272,
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
      "storage_key" => "assets3d/avatar_research.7c86fc428e9f.glb",
      "cdn_path" => "/assets3d/avatar_research.7c86fc428e9f.glb",
      "sha256" => "7c86fc428e9f339c9ecb0b75425c178b1649812b09e5ae8d6f08f8e6c26f40ca",
      "byte_size" => 8_728_120,
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
      "storage_key" => "assets3d/avatar_developer.867211fc6b99.glb",
      "cdn_path" => "/assets3d/avatar_developer.867211fc6b99.glb",
      "sha256" => "867211fc6b99e9d01df3626943f7155cfc7e6ad9fa5f7138bcc5263452770303",
      "byte_size" => 9_320_248,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Engineering / Developer",
        "target_height_m" => 1.75,
        "source" => "meshy developer walk/run + procedural bake + POI clips + rest pose",
        "skeleton" => "mixamo_biped",
        "archetypes" => ["developer", "engineering"]
      }
    },
    %{
      "slug" => "avatar_byte",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_byte.05d5e3743ef8.glb",
      "cdn_path" => "/assets3d/avatar_byte.05d5e3743ef8.glb",
      "sha256" => "05d5e3743ef8ca7fa156addc4a6be6089ef70dbe4fbeccff8722d76e5434eb80",
      "byte_size" => 9_583_064,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Hugo",
        "target_height_m" => 1.75,
        "source" =>
          "Derived from existing Mokaid character; anatomy, rig and 48 animations preserved",
        "skeleton" => "mixamo_biped",
        "donor_slug" => "avatar_corporate",
        "style" =>
          "Human / petrol-blue rolled-sleeve shirt, charcoal tailored trousers, wristwatch",
        "authoring_file" => "artifacts/avatar-atypical/avatar_byte.blend"
      }
    },
    %{
      "slug" => "avatar_nyx",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_nyx.5c7daa1a4ead.glb",
      "cdn_path" => "/assets3d/avatar_nyx.5c7daa1a4ead.glb",
      "sha256" => "5c7daa1a4eadb7cbe07c110da2ec76f2d92d9998cb49197c96cd7f0e08c151c3",
      "byte_size" => 9_668_656,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Inès",
        "target_height_m" => 1.75,
        "source" =>
          "Derived from existing Mokaid character; anatomy, rig and 48 animations preserved",
        "skeleton" => "mixamo_biped",
        "donor_slug" => "avatar_finance",
        "style" =>
          "Human / terracotta blazer, ivory blouse, charcoal trousers, glasses and natural bun",
        "authoring_file" => "artifacts/avatar-atypical/avatar_nyx.blend"
      }
    },
    %{
      "slug" => "avatar_moss",
      "kind" => "character",
      "storage_key" => "assets3d/avatar_moss.96ccd7c01040.glb",
      "cdn_path" => "/assets3d/avatar_moss.96ccd7c01040.glb",
      "sha256" => "96ccd7c01040b0eb4dff82c37d651b0275e335e0fc61202212c61c68519a58f4",
      "byte_size" => 10_672_516,
      "animation_clips" => @all_clips,
      "metadata" => %{
        "display_name" => "Malik",
        "target_height_m" => 1.75,
        "source" =>
          "Derived from existing Mokaid character; anatomy, rig and 48 animations preserved",
        "skeleton" => "mixamo_biped",
        "donor_slug" => "avatar_developer",
        "style" => "Human / forest-green hoodie, dark indigo denim, sneakers, beard and glasses",
        "authoring_file" => "artifacts/avatar-atypical/avatar_moss.blend"
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
