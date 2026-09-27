defmodule Mokaid.AvatarsTest do
  use MokaidWeb.ConnCase, async: false
  import Ecto.Query
  alias Mokaid.{Avatars, Assets3d, Repo}
  alias Mokaid.Avatars.{Generation, Glb, Meshy, Worker}
  alias Mokaid.Billing.{Credits, CreditTransaction, Subscription}

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
    def prepare(glb) do
      send(self(), {:preparing, Mokaid.Repo.in_transaction?()})

      if Process.get(:fail_preparation) do
        {:error, :avatar_preparation_failed}
      else
        {:ok,
         %{
           glb: glb,
           native: "MOKASSETnative-asset",
           portrait: <<0x89, "PNG", 13, 10, 26, 10, 0>>,
           manifest: %{
             "status" => "ready",
             "model_sha256" => Base.encode16(:crypto.hash(:sha256, glb), case: :lower),
             "pipeline_version" => 1,
             "animation_clips" => Mokaid.Avatars.NativeCooker.required_clips(),
             "target_height_m" => 1.75,
             "quality" => %{"clips" => 48},
             "portrait" => %{"size" => [384, 384], "weighted_head_vertices" => 100}
           }
         }}
      end
    end
  end

  setup %{conn: conn} do
    for key <- [:meshy, :avatar_storage, :avatar_native_cooker, :avatar_pipeline_enabled] do
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

    Application.put_env(:mokaid, :avatar_pipeline_enabled, true)
    Application.put_env(:mokaid, :avatar_storage, MemoryStorage)
    Application.put_env(:mokaid, :avatar_native_cooker, NativeCooker)
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)

    %Subscription{}
    |> Subscription.changeset(%{workspace_id: workspace.id, credits_balance: 20_000})
    |> Repo.insert!()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Mokaid.Auth.Token.sign(owner.id))
      |> put_req_header("x-workspace-id", workspace.id)

    {:ok, conn: conn, workspace: workspace, member: member}
  end

  defp create(workspace, member, input) do
    input = Map.put_new(input, "expected_credits", Avatars.pricing().credits)
    Oban.Testing.with_testing_mode(:manual, fn -> Avatars.create(workspace.id, member, input) end)
  end

  defp perform(row),
    do:
      Worker.perform(%Oban.Job{args: %{"generation_id" => row.id}, attempt: 1, max_attempts: 12})

  defp reload(row), do: Avatars.get(row.workspace_id, row.id)

  defp transactions(workspace_id) do
    Repo.all(from t in CreditTransaction, where: t.workspace_id == ^workspace_id)
  end

  defp set_credits(workspace_id, values) do
    from(s in Subscription, where: s.workspace_id == ^workspace_id)
    |> Repo.update_all(set: values)
  end

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

    assert Credits.summary(ctx.workspace.id).spendable == 19_000
    assert [debit] = transactions(ctx.workspace.id)
    assert debit.amount == -1_000
    assert debit.idempotency_key == Avatars.charge_key(row.id)
    assert debit.metadata["avatar_generation_id"] == row.id
    ready = reload(row)
    assert ready.status == "ready"
    assert ready.progress == 100
    assert ready.asset.workspace_id == ctx.workspace.id
    assert ready.asset.animation_clips == Mokaid.Avatars.NativeCooker.required_clips()
    assert_received {:preparing, false}
    assert ready.asset.metadata["portrait_url"] =~ "portrait.png"
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
        post(ctx.conn, "/api/avatar-generations", %{
          mode: "text",
          prompt: "A curious researcher",
          expected_credits: 1_000
        })
      end)

    assert %{"data" => %{"id" => id, "status" => "queued"}} = json_response(response, 202)

    assert %{"data" => %{"id" => ^id}} =
             ctx.conn |> get("/api/avatar-generations/#{id}") |> json_response(200)

    assert ctx.conn |> get("/api/avatar-generations/#{Ecto.UUID.generate()}") |> response(404)
  end

  test "quote exposes Mokaid price and workspace balance before a paid submission", ctx do
    assert %{
             "data" => [],
             "meta" => %{
               "pricing" => %{"credits" => 1_000},
               "credits" => %{"spendable" => 20_000, "unlimited" => false}
             }
           } = ctx.conn |> get("/api/avatar-generations") |> json_response(200)

    for {expected, code} <- [
          {nil, "avatar_price_confirmation_required"},
          {500, "avatar_price_changed"},
          {"1000evil", "avatar_price_changed"},
          {1000.0, "avatar_price_changed"}
        ] do
      input = %{mode: "text", prompt: "A researcher"}
      input = if is_nil(expected), do: input, else: Map.put(input, :expected_credits, expected)

      assert %{"error" => %{"code" => ^code}} =
               ctx.conn |> post("/api/avatar-generations", input) |> json_response(422)
    end

    assert Avatars.list(ctx.workspace.id) == []
    assert transactions(ctx.workspace.id) == []
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Credits.summary(ctx.workspace.id).spendable == 20_000
  end

  test "insufficient prepaid balance rolls back generation and enqueue", ctx do
    set_credits(ctx.workspace.id, credits_balance: 999, auto_recharge_enabled: true)

    assert {:error, :insufficient_credits} =
             create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})

    assert Avatars.list(ctx.workspace.id) == []
    assert transactions(ctx.workspace.id) == []
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Credits.summary(ctx.workspace.id).spendable == 999

    from(s in Subscription, where: s.workspace_id == ^ctx.workspace.id) |> Repo.delete_all()

    assert {:error, :insufficient_credits} =
             create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})

    assert Avatars.list(ctx.workspace.id) == []
  end

  test "multipart string quote is accepted and creation debits immediately", ctx do
    {:ok, row} =
      create(ctx.workspace, ctx.member, %{
        "mode" => "text",
        "prompt" => "An engineer",
        "expected_credits" => "1000"
      })

    assert row.status == "queued"
    assert Credits.summary(ctx.workspace.id).spendable == 19_000
    assert [debit] = transactions(ctx.workspace.id)
    assert debit.amount == -1_000
    assert debit.metadata["avatar_generation_id"] == row.id
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "terminal failure restores the original credit buckets once", ctx do
    set_credits(ctx.workspace.id, included_credits_remaining: 600, credits_balance: 400)
    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 402, "private provider failure"))
    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})
    assert Credits.summary(ctx.workspace.id).spendable == 0
    assert :ok = perform(row)
    assert :ok = perform(row)
    assert reload(row).status == "failed"

    assert %{included_remaining: 600, balance: 400, spendable: 1_000} =
             Credits.summary(ctx.workspace.id)

    assert [refund] = Enum.filter(transactions(ctx.workspace.id), &(&1.amount > 0))
    assert refund.amount == 1_000
    assert refund.idempotency_key == Avatars.charge_key(row.id) <> ":refund"
    assert refund.metadata["avatar_generation_id"] == row.id
    refute reload(row).error =~ "Meshy"
  end

  test "failed generation refund survives a monthly credit reset", ctx do
    before_reset = DateTime.add(DateTime.utc_now(), -3600, :second)

    set_credits(ctx.workspace.id,
      included_credits_remaining: 1_000,
      credits_balance: 0,
      credits_period_start: before_reset
    )

    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 402, "unavailable"))
    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})

    set_credits(ctx.workspace.id,
      included_credits_remaining: 2_000,
      credits_period_start: DateTime.utc_now()
    )

    assert :ok = perform(row)

    assert %{included_remaining: 2_000, balance: 1_000, spendable: 3_000} =
             Credits.summary(ctx.workspace.id)
  end

  test "unlimited plans and legacy uncharged failures do not create a refund", ctx do
    set_credits(ctx.workspace.id,
      monthly_credits: -1,
      included_credits_remaining: -1,
      credits_balance: 0
    )

    Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 402, "unavailable"))
    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})
    assert :ok = perform(row)
    assert transactions(ctx.workspace.id) == []

    assert %{included_remaining: -1, balance: 0, unlimited: true} =
             Credits.summary(ctx.workspace.id)

    legacy =
      %Generation{}
      |> Generation.changeset(%{
        workspace_id: ctx.workspace.id,
        mode: "text",
        name: "Legacy",
        prompt: "A researcher"
      })
      |> Repo.insert!()

    assert :ok = perform(legacy)
    assert transactions(ctx.workspace.id) == []
  end

  test "previously stored failures expose generic service branding", ctx do
    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})

    row =
      row
      |> Generation.changeset(%{error: "Meshy could not create this character."})
      |> Repo.update!()

    refute Avatars.serialize(row).error =~ "Meshy"
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
    assert Credits.summary(ctx.workspace.id).spendable == 20_000
    assert Enum.sort(Enum.map(transactions(ctx.workspace.id), & &1.amount)) == [-1_000, 1_000]
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
    assert Credits.summary(ctx.workspace.id).spendable == 20_000
    assert Enum.sort(Enum.map(transactions(ctx.workspace.id), & &1.amount)) == [-1_000, 1_000]
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
    assert build_conn() |> get(native) |> response(200) == "MOKASSETnative-asset"
    portrait = URI.parse(ready.asset.metadata["portrait_url"]).path
    assert <<0x89, "PNG", _::binary>> = build_conn() |> get(portrait) |> response(200)
  end

  test "generation is unavailable before charging when the complete worker is disabled", ctx do
    Application.put_env(:mokaid, :avatar_pipeline_enabled, false)

    assert {:error, :avatar_generation_unavailable} =
             create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})

    assert Credits.summary(ctx.workspace.id).spendable == 20_000
    assert transactions(ctx.workspace.id) == []
  end

  test "incomplete animation preparation never becomes ready and refunds once", ctx do
    stub_pipeline()
    Process.put(:fail_preparation, true)
    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})
    for _ <- 1..4, do: perform(row)
    failed = reload(row)
    assert failed.status == "failed"
    assert failed.asset_id == nil
    assert failed.error =~ "office animations"
    assert Credits.summary(ctx.workspace.id).spendable == 20_000
    assert :ok = perform(row)
    assert length(transactions(ctx.workspace.id)) == 2
  end

  test "interrupted local preparation resumes without another paid provider submission", ctx do
    stub_pipeline()
    {:ok, row} = create(ctx.workspace, ctx.member, %{"mode" => "text", "prompt" => "An engineer"})
    for _ <- 1..3, do: perform(row)
    claim = "preparing:" <> Ecto.UUID.generate() <> ":rig-1"
    row |> Generation.changeset(%{status: "saving", task_id: claim}) |> Repo.update!()
    assert {:snooze, 15} = perform(row)
    refute_received {:preparing, _}

    from(g in Generation, where: g.id == ^row.id)
    |> Repo.update_all(set: [updated_at: DateTime.add(DateTime.utc_now(), -901, :second)])

    assert :ok = perform(row)
    assert reload(row).status == "ready"
    assert Credits.summary(ctx.workspace.id).spendable == 19_000
    assert_received {:upstream, "POST", "/openapi/v1/rigging", _}
    refute_received {:upstream, "POST", "/openapi/v1/rigging", _}
  end
end
