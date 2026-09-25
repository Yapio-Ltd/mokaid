defmodule Mokaid.Avatars.StorageTest do
  use ExUnit.Case, async: false
  alias Mokaid.Avatars.Storage

  defmodule S3Fixture do
    @behaviour Plug
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:s3, conn.method, conn.request_path, conn.req_headers, body})

      case conn.method do
        "PUT" ->
          conn |> Plug.Conn.put_resp_header("etag", "fixture") |> Plug.Conn.send_resp(200, "")

        "GET" ->
          conn
          |> Plug.Conn.put_resp_content_type("image/png")
          |> Plug.Conn.send_resp(200, <<0, 1, 2, 255>>)

        "DELETE" ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end
  end

  setup do
    server =
      start_supervised!(
        {Bandit, plug: {S3Fixture, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    replace_env(:ex_aws, :s3,
      access_key_id: "TEST",
      secret_access_key: "test-secret",
      region: "us-east-1",
      scheme: "http://",
      host: "127.0.0.1",
      port: port,
      retries: [max_attempts: 1]
    )

    replace_env(:mokaid, :storage,
      bucket_uploads: "private-uploads",
      bucket_assets_3d: "generated-assets"
    )

    :ok
  end

  test "generated models persist in the asset bucket with binary MIME and immutable cache headers" do
    data = <<0, 255, 3, 4>>
    key = "assets3d/generated-characters/workspace/generation.glb"
    assert :ok = Storage.put_asset(key, data, "model/gltf-binary")
    assert_receive {:s3, "PUT", "/generated-assets/" <> ^key, headers, ^data}
    assert {"content-type", "model/gltf-binary"} in headers
    assert {"cache-control", "public, max-age=31536000, immutable"} in headers
    assert {:ok, <<0, 1, 2, 255>>} = Storage.get_asset(key)
    assert_receive {:s3, "GET", "/generated-assets/" <> ^key, _, ""}
  end

  test "source photos use the private upload bucket and can be deleted after use" do
    bytes = <<0x89, "PNG", 13, 10, 26, 10>>
    assert {:ok, %{storage_key: key}} = Storage.put_source("workspace-id", bytes, "image/png")
    assert key =~ "workspaces/workspace-id/drive/"
    assert_receive {:s3, "PUT", "/private-uploads/" <> ^key, headers, ^bytes}
    refute Enum.any?(headers, fn {name, _} -> name == "x-amz-acl" end)
    assert {:ok, _, "image/png"} = Storage.get_source(key)
    assert :ok = Storage.delete_source(key)
    assert_receive {:s3, "DELETE", "/private-uploads/" <> ^key, _, ""}
  end

  defp replace_env(app, key, value) do
    old = Application.fetch_env(app, key)

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)

    Application.put_env(app, key, value)
  end
end
