defmodule Mokaid.AvatarsTest do
  use MokaidWeb.ConnCase, async: false
  import Ecto.Query
  alias Mokaid.{Avatars, Assets3d, Repo}
  alias Mokaid.Avatars.{Generation, Glb, Meshy, Worker}

  defmodule MemoryStorage do
    def put_asset(key, data, _type) do
      Process.put({:asset, key}, data)
      :ok
    end

    def get_asset(key), do: {:ok, Process.get({:asset, key})}

    def put_source(_workspace, data, type) do
      Process.put(:source, {data, type})
      {:ok, %{storage_key: "source/test"}}
    end

    def get_source(_key) do
      {data, type} = Process.get(:source)
      {:ok, data, type}
    end

    def delete_source(key) do
      if key, do: send(self(), {:deleted_source, key})
      :ok
    end
  end

  defmodule NativeCooker do
    def cook(_), do: {:ok, "native-asset"}
  end

  setup %{conn: conn} do
    for key <- [:meshy, :avatar_storage, :avatar_native_cooker] do
      old = Application.get_env(:mokaid, key)

      on_exit(fn ->
        if old,
          do: Application.put_env(:mokaid, key, old),
          else: Application.delete_env(:mokaid, key)
      end)
    end

    Application.put_env(:mokaid, :meshy,
      api_key: "test-key",
      request_options: [plug: {Req.Test, __MODULE__}],
      download_options: [plug: {Req.Test, __MODULE__}]
    )

    Application.put_env(:mokaid, :avatar_storage, MemoryStorage)
    Application.put_env(:mokaid, :avatar_native_cooker, NativeCooker)
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Mokaid.Auth.Token.sign(owner.id))
      |> put_req_header("x-workspace-id", workspace.id)

    {:ok, conn: conn, workspace: workspace, member: member}
  end

  defp create(workspace, member, input) do
    Oban.Testing.with_testing_mode(:manual, fn -> Avatars.create(workspace.id, member, input) end)
  end

  defp perform(row),
    do:
      Worker.perform(%Oban.Job{args: %{"generation_id" => row.id}, attempt: 1, max_attempts: 12})

  defp reload(row), do: Avatars.get(row.workspace_id, row.id)

  defp glb(overrides \\ %{}) do
    json =
      %{
        asset: %{version: "2.0"},
        meshes: [%{}],
        buffers: [%{byteLength: 4}],
        animations: [%{name: "Walking", samplers: [], channels: []}]
      }
      |> Map.merge(overrides)
      |> Jason.encode!()

    padded = json <> String.duplicate(" ", rem(4 - rem(byte_size(json), 4), 4))
    size = 32 + byte_size(padded)

    <<"glTF", 2::little-32, size::little-32, byte_size(padded)::little-32, 0x4E4F534A::little-32,
      padded::binary, 4::little-32, 0x004E4942::little-32, 0::32>>
  end

  defp stub_pipeline do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      data = if body == "", do: %{}, else: Jason.decode!(body)
      send(self(), {:upstream, conn.method, conn.request_path, data})

      case {conn.method, conn.request_path} do
        {"POST", "/openapi/v2/text-to-3d"} ->
          Req.Test.json(conn, %{
            result: if(data["mode"] == "preview", do: "preview-1", else: "refine-1")
          })

        {"POST", "/openapi/v1/image-to-3d"} ->
          Req.Test.json(conn, %{result: "image-1"})

        {"POST", "/openapi/v1/rigging"} ->
          Req.Test.json(conn, %{result: "rig-1"})

        {"GET", "/openapi/v1/rigging/rig-1"} ->
          Req.Test.json(conn, %{
            status: "SUCCEEDED",
            result: %{basic_animations: %{walking_glb_url: "https://assets.meshy.ai/model.glb"}}
          })

        {"GET", "/model.glb"} ->
          Plug.Conn.send_resp(conn, 200, glb())

        {"GET", "/thumbnail.png"} ->
          Plug.Conn.send_resp(conn, 200, <<0x89, "PNG", 13, 10, 26, 10, 0>>)

        {"GET", _} ->
          Req.Test.json(conn, %{
            status: "SUCCEEDED",
            thumbnail_url: "https://assets.meshy.ai/thumbnail.png"
          })
      end
    end)
  end

  test "text pipeline refines, rigs at 1.75m and stores durable native and GLB assets exactly once",
       ctx do
    stub_pipeline()

    {:ok, row} =
      create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "A friendly engineer"})

    assert row.status == "queued"
    assert {:snooze, 15} = perform(row)
    assert reload(row).status == "generating"
    assert {:snooze, 15} = perform(row)
    assert reload(row).status == "texturing"
    assert {:snooze, 15} = perform(row)
    assert reload(row).status == "rigging"
    assert :ok = perform(row)
    ready = reload(row)
    assert ready.status == "ready"
    assert ready.progress == 100
    assert ready.asset.workspace_id == ctx.workspace.id
    assert ready.asset.animation_clips == ["walking"]
    assert ready.asset.metadata["target_height_m"] == 1.75
    assert ready.asset.cdn_path =~ "/api/avatar-assets/#{row.id}/"
    assert ready.asset.metadata["native_cdn_path"] =~ "model.mokaidasset"
    assert ready.thumbnail_url =~ "thumbnail.png"
    assert {:ok, stored} = MemoryStorage.get_asset(ready.asset.storage_key)
    assert <<"glTF", _::binary>> = stored
    assert :ok = perform(row)

    assert Repo.aggregate(
             from(a in Mokaid.Assets3d.Asset, where: a.workspace_id == ^ctx.workspace.id),
             :count
           ) == 1

    assert_received {:upstream, "POST", "/openapi/v1/rigging",
                     %{"height_meters" => 1.75, "input_task_id" => "refine-1"}}

    assert_received {:upstream, "POST", "/openapi/v2/text-to-3d",
                     %{"mode" => "refine", "preview_task_id" => "preview-1"}}

    refute Map.has_key?(Avatars.serialize(ready).asset.metadata, "media_token")
  end

  test "photo is verified by magic bytes, persisted privately and deleted on completion", ctx do
    stub_pipeline()
    path = Path.join(System.tmp_dir!(), "avatar-test-#{Ecto.UUID.generate()}.png")
    bytes = <<0x89, "PNG", 13, 10, 26, 10, 0>>
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    upload = %Plug.Upload{
      path: path,
      filename: "photo.png",
      content_type: "application/octet-stream"
    }

    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "image", "file" => upload})
    assert row.source_storage_key == "source/test"
    assert {:snooze, 15} = perform(row)
    assert_received {:upstream, "POST", "/openapi/v1/image-to-3d", %{"image_url" => image}}
    assert image == "data:image/png;base64," <> Base.encode64(bytes)
    assert {:snooze, 15} = perform(row)
    assert :ok = perform(row)
    assert reload(row).status == "ready"
    assert_received {:deleted_source, "source/test"}
  end

  test "validates inputs and prevents arbitrary remote image URLs" do
    assert {:error, :invalid_avatar_prompt} =
             Avatars.validate_input(%{"mode" => "text", "prompt" => "  "})

    assert {:error, :invalid_avatar_prompt} =
             Avatars.validate_input(%{"mode" => "text", "prompt" => String.duplicate("a", 601)})

    assert {:error, :invalid_avatar_input} =
             Avatars.validate_input(%{
               "mode" => "image",
               "image_url" => "http://169.254.169.254/"
             })

    assert {:error, :invalid_asset_url} =
             Meshy.download("https://assets.meshy.ai.evil.test/file.glb")

    assert {:error, :invalid_asset_url} = Meshy.download("http://assets.meshy.ai/file.glb")
    assert {:error, :invalid_avatar_image} = Avatars.image_type("<svg></svg>")
  end

  test "unsupported WebP is rejected before submitting a paid task" do
    path = Path.join(System.tmp_dir!(), "avatar-format-#{Ecto.UUID.generate()}.webp")
    File.write!(path, <<"RIFF", 0::32, "WEBP", 0::32>>)
    on_exit(fn -> File.rm(path) end)
    upload = %Plug.Upload{path: path, filename: "photo.webp", content_type: "image/webp"}

    assert {:error, :invalid_avatar_image} =
             Avatars.validate_input(%{"mode" => "image", "file" => upload})
  end

  test "invalid GLB and external buffer links are rejected" do
    assert {:error, :invalid_glb} = Glb.prepare("not a model")

    assert {:error, :invalid_glb} =
             Glb.prepare(glb(%{buffers: [%{uri: "https://internal/model.bin"}]}))

    assert {:error, :invalid_glb} =
             Glb.prepare(glb(%{images: [%{uri: "file:///private/image.png"}]}))

    assert {:ok, data} = Glb.prepare(glb())
    assert data =~ "walking"
  end

  test "limits concurrent generations and isolates workspace history", ctx do
    {:ok, first} =
      create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})

    {:ok, _} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "A designer"})

    assert {:error, :avatar_generation_in_progress} =
             create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "A lawyer"})

    {other, _} = workspace_fixture()
    assert Avatars.list(other.id) == []
    assert Avatars.get(other.id, first.id) == nil
    assert Avatars.get(ctx.workspace.id, "invalid") == nil
  end

  test "POST acceptance, polling and unknown generation are scoped", ctx do
    response =
      Oban.Testing.with_testing_mode(:manual, fn ->
        post(ctx.conn, "/api/avatar-generations", %{mode: "text", prompt: "A curious researcher"})
      end)

    assert %{"data" => %{"id" => id, "status" => "queued"}} = json_response(response, 202)

    assert %{"data" => %{"id" => ^id}} =
             ctx.conn |> get("/api/avatar-generations/#{id}") |> json_response(200)

    assert ctx.conn |> get("/api/avatar-generations/#{Ecto.UUID.generate()}") |> response(404)
  end

  test "a committed unresolved paid-stage claim is never resubmitted after a crash", ctx do
    Req.Test.stub(__MODULE__, fn _ ->
      flunk("an ambiguous Meshy request must never be resubmitted")
    end)

    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})

    row
    |> Generation.changeset(%{
      task_id: "submitting:lost-process",
      task_kind: "text",
      status: "generating"
    })
    |> Repo.update!()

    assert {:snooze, 15} = perform(row)
    old = DateTime.add(DateTime.utc_now(), -121, :second)
    from(g in Generation, where: g.id == ^row.id) |> Repo.update_all(set: [updated_at: old])
    assert :ok = perform(row)
    assert reload(row).status == "failed"
    assert reload(row).error =~ "could not confirm"
    assert :ok = perform(row)
  end

  test "paid POST failures are not retried and expose no provider response", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 402, "sensitive upstream message")
    end)

    {:ok, row} =
      create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An office robot"})

    assert :ok = perform(row)
    assert reload(row).status == "failed"
    assert reload(row).error =~ "credits"
    refute reload(row).error =~ "sensitive"
    assert :ok = perform(row)
  end

  test "webhook payload cannot forge success or asset URL, duplicates don't multiply jobs", ctx do
    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})

    row
    |> Generation.changeset(%{task_id: "known-task", task_kind: "text", status: "generating"})
    |> Repo.update!()

    payload = %{
      "id" => "known-task",
      "status" => "SUCCEEDED",
      "model_urls" => %{"glb" => "http://internal/secret"}
    }

    body = Jason.encode!(payload)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _} = Avatars.webhook_hint(payload, body)
      assert {:ok, _} = Avatars.webhook_hint(payload, body)
    end)

    assert reload(row).status == "generating"
    assert reload(row).asset_id == nil
    assert Repo.aggregate("meshy_webhook_deliveries", :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
    assert {:ok, :ignored} = Avatars.webhook_hint(%{"id" => "unknown"}, "x")

    assert build_conn() |> post("/api/webhooks/meshy", %{id: "unknown"}) |> json_response(202) ==
             %{"ok" => true}
  end

  test "custom assets are hidden from other workspaces and rejected for assignment", ctx do
    stub_pipeline()
    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})
    for _ <- 1..4, do: perform(row)
    asset = reload(row).asset
    {other, _} = workspace_fixture()
    assert Assets3d.list_assets() == []
    assert [%{id: id}] = Assets3d.list_assets(workspace_id: ctx.workspace.id)
    assert id == asset.id
    assert Assets3d.get_visible_asset(asset.id, other.id) == nil

    assert {:error, :invalid_avatar_asset} =
             Mokaid.Agents.create_agent(other.id, %{
               "kind" => "ai",
               "display_name" => "Other",
               "avatar_asset_id" => asset.id
             })

    assert :ok = Assets3d.validate_avatar(ctx.workspace.id, asset.id)

    assert ctx.conn
           |> get("/api/assets-3d")
           |> json_response(200)
           |> Map.fetch!("data")
           |> length() == 1

    assert ctx.conn
           |> put_req_header("x-workspace-id", other.id)
           |> get("/api/assets-3d/#{asset.id}")
           |> response(404)
  end

  test "media requires correct capability and returns persisted model", ctx do
    stub_pipeline()
    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})
    for _ <- 1..4, do: perform(row)
    ready = reload(row)
    path = URI.parse(ready.asset.cdn_path).path
    assert build_conn() |> get(path) |> response(200) =~ "glTF"
    wrong = "/api/avatar-assets/#{row.id}/wrong/model.glb"
    assert build_conn() |> get(wrong) |> response(404)
    native = URI.parse(ready.asset.metadata["native_cdn_path"]).path
    assert build_conn() |> get(native) |> response(200) == "native-asset"
  end
end
