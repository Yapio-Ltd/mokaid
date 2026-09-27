defmodule Mokaid.AvatarRepairTest do
  use Mokaid.DataCase, async: false

  alias Mokaid.Agents.Agent
  alias Mokaid.Assets3d.Asset
  alias Mokaid.Avatars.{Generation, NativeCooker, PreparedAsset, RepairWorker}
  alias Mokaid.Billing.{CreditTransaction, Subscription}

  defmodule MemoryStorage do
    def put_asset(key, bytes, type) do
      send(self(), {:stored, key, type})

      if String.ends_with?(key, Process.get(:fail_suffix, "impossible-suffix")) do
        {:error, :storage_unavailable}
      else
        Process.put({:asset, key}, bytes)
        :ok
      end
    end

    def get_asset(key) do
      send(self(), {:read_asset, key})

      case Process.get({:asset, key}) do
        nil -> {:error, :not_found}
        bytes -> {:ok, bytes}
      end
    end
  end

  defmodule Cooker do
    def prepare(glb) do
      send(self(), {:prepared, Mokaid.Repo.in_transaction?()})
      if hook = Process.get(:prepare_hook), do: hook.()

      manifest = %{
        "status" => "ready",
        "model_sha256" => digest(glb),
        "pipeline_version" => 1,
        "animation_clips" => NativeCooker.required_clips(),
        "target_height_m" => 1.75,
        "quality" => %{"clips" => 48},
        "portrait" => %{"size" => [384, 384], "weighted_head_vertices" => 100}
      }

      case Process.get(:prepare_failure) do
        :failure ->
          {:error, :avatar_preparation_failed}

        other ->
          manifest =
            case other do
              :incomplete -> Map.put(manifest, "animation_clips", ["idle"])
              :wrong_hash -> Map.put(manifest, "model_sha256", String.duplicate("0", 64))
              :missing_quality -> Map.delete(manifest, "quality")
              _ -> manifest
            end

          {:ok,
           %{
             glb: glb,
             native: "MOKASSETnative-asset",
             portrait: Mokaid.AvatarRepairTest.png(),
             manifest: manifest
           }}
      end
    end

    defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  setup do
    for {key, value} <- [avatar_storage: MemoryStorage, avatar_native_cooker: Cooker] do
      previous = Application.fetch_env(:mokaid, key)
      Application.put_env(:mokaid, key, value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:mokaid, key, value)
          :error -> Application.delete_env(:mokaid, key)
        end
      end)
    end

    {workspace, _owner} = workspace_fixture()

    subscription =
      %Subscription{}
      |> Subscription.changeset(%{workspace_id: workspace.id, credits_balance: 4000})
      |> Repo.insert!()

    asset =
      %Asset{}
      |> Asset.changeset(%{
        workspace_id: workspace.id,
        slug: "old_#{Ecto.UUID.generate()}",
        kind: "character",
        storage_key: "old/character.glb",
        cdn_path: "https://example.invalid/old-token/model.glb",
        sha256: String.duplicate("a", 64),
        byte_size: 42,
        animation_clips: ["walk"],
        metadata: %{
          "custom" => true,
          "media_token" => "old-token",
          "thumbnail_url" => "https://example.invalid/old-token/thumbnail.png"
        }
      })
      |> Repo.insert!()

    generation =
      %Generation{}
      |> Generation.changeset(%{
        workspace_id: workspace.id,
        asset_id: asset.id,
        mode: "text",
        name: "Goku",
        status: "ready",
        progress: 100,
        thumbnail_source_url: "https://never-call-the-provider.invalid/thumbnail.png",
        thumbnail_url: asset.metadata["thumbnail_url"]
      })
      |> Repo.insert!()
      |> Repo.preload(:asset)

    agent =
      %Agent{}
      |> Agent.create_changeset(%{
        workspace_id: workspace.id,
        kind: "ai",
        display_name: "Goku",
        avatar_asset_id: asset.id
      })
      |> Repo.insert!()

    Process.put({:asset, asset.storage_key}, glb())
    Process.put({:asset, "old/character.png"}, png())

    {:ok,
     workspace: workspace,
     subscription: subscription,
     generation: generation,
     asset: asset,
     agent: agent}
  end

  test "publisher returns complete immutable revisions without changing database rows", ctx do
    input = %{ctx.generation | thumbnail_source_url: nil}
    assert {:ok, first} = PreparedAsset.prepare(input, glb())
    assert {:ok, second} = PreparedAsset.prepare(input, glb())
    assert first.storage_key != second.storage_key
    assert first.metadata["media_token"] != second.metadata["media_token"]
    assert String.contains?(first.storage_key, "/#{ctx.generation.id}/")
    assert first.animation_clips == NativeCooker.required_clips()
    assert first.metadata["pipeline_version"] == 1
    assert first.metadata["quality"]["clips"] == 48
    assert first.metadata["thumbnail_url"] == first.metadata["portrait_url"]
    assert String.ends_with?(first.metadata["portrait_url"], "/portrait.png")
    assert first.metadata["portrait_content_type"] == "image/png"
    assert_receive {:prepared, false}
    assert Repo.get!(Asset, ctx.asset.id) == ctx.asset
    assert Repo.aggregate(Asset, :count) == 1
    assert Process.get({:asset, first.storage_key})

    assert Process.get(
             {:asset, String.replace_suffix(first.storage_key, ".glb", ".portrait.png")}
           )
  end

  test "publisher fails closed on incomplete quality or a mismatched enriched GLB", ctx do
    for failure <- [:incomplete, :missing_quality, :wrong_hash] do
      Process.put(:prepare_failure, failure)
      assert {:error, _} = PreparedAsset.prepare(ctx.generation, glb())
      refute_receive {:stored, _, _}
    end
  end

  test "repair preserves identity, assignment and credits and copies the stored body preview",
       ctx do
    assert :ok = perform(ctx.generation)
    assert_receive {:prepared, false}
    assert_receive {:read_asset, "old/character.glb"}
    assert_receive {:read_asset, "old/character.png"}
    repaired = Repo.get!(Asset, ctx.asset.id)
    generation = Repo.get!(Generation, ctx.generation.id)
    assert repaired.id == ctx.asset.id
    assert repaired.slug == ctx.asset.slug
    assert repaired.workspace_id == ctx.asset.workspace_id
    assert repaired.metadata["media_token"] != "old-token"
    assert repaired.storage_key != ctx.asset.storage_key
    assert repaired.animation_clips == NativeCooker.required_clips()
    assert repaired.metadata["quality"]["clips"] == 48
    assert String.ends_with?(repaired.metadata["thumbnail_url"], "/thumbnail.png")
    assert generation.thumbnail_url == repaired.metadata["thumbnail_url"]
    assert generation.status == "ready"
    assert generation.progress == 100
    assert generation.asset_id == ctx.asset.id
    assert Repo.get!(Agent, ctx.agent.id).avatar_asset_id == ctx.asset.id
    assert Repo.get!(Subscription, ctx.subscription.id) == ctx.subscription
    assert Repo.aggregate(CreditTransaction, :count) == 0
    assert Process.get({:asset, ctx.asset.storage_key}) == glb()

    # A retry after the atomic replacement is already complete performs no work.
    assert :ok = perform(generation)
    refute_receive {:prepared, _}
    assert Repo.get!(Asset, ctx.asset.id) == repaired
  end

  test "failed render or mandatory portrait upload leaves the working character untouched", ctx do
    Process.put(:prepare_failure, :failure)
    assert {:error, :avatar_preparation_failed} = perform(ctx.generation)
    assert_original(ctx)

    Process.delete(:prepare_failure)
    Process.put(:fail_suffix, ".portrait.png")
    assert {:error, :storage_unavailable} = perform(ctx.generation)
    assert_original(ctx)
  end

  test "optional thumbnail failure uses the required portrait", ctx do
    Process.delete({:asset, "old/character.png"})
    assert :ok = perform(ctx.generation)
    repaired = Repo.get!(Asset, ctx.asset.id)
    assert repaired.metadata["thumbnail_url"] == repaired.metadata["portrait_url"]
  end

  test "a stale repair cannot overwrite a concurrently published revision", ctx do
    Process.put(:prepare_hook, fn ->
      ctx.asset
      |> Asset.changeset(%{storage_key: "newer/revision.glb", sha256: String.duplicate("b", 64)})
      |> Repo.update!()
    end)

    assert :ok = perform(ctx.generation)
    assert Repo.get!(Asset, ctx.asset.id).storage_key == "newer/revision.glb"
    assert Repo.get!(Generation, ctx.generation.id).thumbnail_url == ctx.generation.thumbnail_url
    assert Repo.get!(Subscription, ctx.subscription.id) == ctx.subscription
  end

  test "enqueue deduplicates a ready generation and rejects missing or unfinished work", ctx do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, first} = RepairWorker.enqueue(ctx.generation.id)
      assert {:ok, second} = RepairWorker.enqueue(ctx.generation.id)
      assert first.id == second.id
      assert second.conflict?
      assert first.queue == "avatars"
      assert {:error, :avatar_not_ready} = RepairWorker.enqueue(Ecto.UUID.generate())
      assert {:error, :avatar_not_ready} = RepairWorker.enqueue("not-a-uuid")
      ctx.generation |> Generation.changeset(%{status: "rigging"}) |> Repo.update!()
      assert {:error, :avatar_not_ready} = RepairWorker.enqueue(ctx.generation.id)
    end)
  end

  defp assert_original(ctx) do
    assert Repo.get!(Asset, ctx.asset.id) == ctx.asset
    assert Repo.get!(Generation, ctx.generation.id).status == "ready"
    assert Repo.get!(Generation, ctx.generation.id).thumbnail_url == ctx.generation.thumbnail_url
    assert Repo.get!(Subscription, ctx.subscription.id) == ctx.subscription
    assert Repo.aggregate(CreditTransaction, :count) == 0
  end

  defp perform(row), do: RepairWorker.perform(%Oban.Job{args: %{"generation_id" => row.id}})

  def png, do: <<0x89, "PNG", 13, 10, 26, 10, 0>>

  defp glb do
    json =
      Jason.encode!(%{
        asset: %{version: "2.0"},
        meshes: [%{}],
        buffers: [%{byteLength: 4}],
        animations: [%{name: "Walking", samplers: [], channels: []}]
      })

    padded = json <> String.duplicate(" ", rem(4 - rem(byte_size(json), 4), 4))
    size = 32 + byte_size(padded)

    <<"glTF", 2::little-32, size::little-32, byte_size(padded)::little-32, 0x4E4F534A::little-32,
      padded::binary, 4::little-32, 0x004E4942::little-32, 0::32>>
  end
end
