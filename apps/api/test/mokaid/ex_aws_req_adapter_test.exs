defmodule Mokaid.ExAwsReqAdapterTest do
  # Storage consumer tests temporarily replace application configuration.
  use ExUnit.Case, async: false

  # A real loopback HTTP server exercises the production ExAws -> Req -> Finch
  # transport. All credentials, payloads and endpoints are synthetic and local.
  defmodule Fixture do
    @behaviour Plug

    @impl true
    def init(owner), do: owner

    @impl true
    def call(conn, owner) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:fixture_request, conn.method, conn.request_path, conn.req_headers, body})

      case conn.request_path do
        "/fixture-bucket/denied" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/xml")
          |> Plug.Conn.send_resp(403, "<Error><Code>AccessDenied</Code></Error>")

        "/fixture-bucket/redirect" ->
          conn
          |> Plug.Conn.put_resp_header("location", "/fixture-bucket/must-not-follow")
          |> Plug.Conn.send_resp(301, "")

        "/fixture-bucket/binary" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/octet-stream")
          |> Plug.Conn.put_resp_header("etag", "\"fixture-etag\"")
          |> Plug.Conn.send_resp(200, <<0, 1, 2, 255, 13, 10>>)

        "/fixture-bucket/mime/" <> extension ->
          content_type =
            Map.fetch!(
              %{"png" => "image/png", "pdf" => "application/pdf", "html" => "text/html"},
              extension
            )

          conn
          |> Plug.Conn.put_resp_content_type(content_type)
          |> Plug.Conn.send_resp(200, "synthetic #{extension} fixture")

        "/json" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/x-amz-json-1.1")
          |> Plug.Conn.send_resp(200, ~s({"Events":[],"NextToken":"fixture-next"}))

        "/fixture-bucket/upload" ->
          conn
          |> Plug.Conn.put_resp_header("etag", "\"uploaded-fixture\"")
          |> Plug.Conn.send_resp(200, "")

        _ ->
          Plug.Conn.send_resp(conn, 404, "Unexpected fixture endpoint")
      end
    end
  end

  setup context do
    server =
      start_supervised!(
        {Bandit, plug: {Fixture, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    config = [
      access_key_id: "FIXTURE-ACCESS-KEY",
      secret_access_key: "fixture-secret-not-a-real-credential",
      region: "us-east-1",
      scheme: "http://",
      host: "127.0.0.1",
      port: port,
      retries: [max_attempts: 1, base_backoff_in_ms: 0, max_backoff_in_ms: 0]
    ]

    if context[:storage] do
      replace_env(:ex_aws, :s3, config)
      replace_env(:mokaid, :storage, bucket_uploads: "fixture-bucket")
    end

    %{config: config}
  end

  test "production config selects the official Req adapter for all AWS consumers", %{
    config: config
  } do
    assert Application.fetch_env!(:ex_aws, :http_client) == ExAws.Request.Req

    for service <- [:s3, :sqs, :logs, :ce] do
      assert ExAws.Config.new(service, config).http_client == ExAws.Request.Req
    end
  end

  test "S3 GET preserves binary bodies, headers and SigV4 signing", %{config: config} do
    assert {:ok, %{status_code: 200, body: <<0, 1, 2, 255, 13, 10>>, headers: headers}} =
             "fixture-bucket" |> ExAws.S3.get_object("binary") |> ExAws.request(config)

    assert {"etag", "\"fixture-etag\""} in headers
    assert_receive {:fixture_request, "GET", "/fixture-bucket/binary", request_headers, ""}

    assert Enum.any?(request_headers, fn {name, value} ->
             name == "authorization" and String.starts_with?(value, "AWS4-HMAC-SHA256 ")
           end)
  end

  test "S3 PUT preserves uploaded bytes and content type", %{config: config} do
    payload = <<0, 3, 255, "local fixture">>

    assert {:ok, %{status_code: 200}} =
             "fixture-bucket"
             |> ExAws.S3.put_object("upload", payload, content_type: "application/octet-stream")
             |> ExAws.request(config)

    assert_receive {:fixture_request, "PUT", "/fixture-bucket/upload", headers, ^payload}
    assert {"content-type", "application/octet-stream"} in headers
  end

  test "JSON operations retain serialization and AWS target headers", %{config: config} do
    operation = %ExAws.Operation.JSON{
      service: :logs,
      path: "/json",
      data: %{"logGroupName" => "local-fixture"},
      headers: [{"x-amz-target", "Logs_20140328.FilterLogEvents"}]
    }

    assert {:ok, %{"Events" => [], "NextToken" => "fixture-next"}} =
             ExAws.request(operation, config)

    assert_receive {:fixture_request, "POST", "/json", headers, body}
    assert Jason.decode!(body) == %{"logGroupName" => "local-fixture"}
    assert {"x-amz-target", "Logs_20140328.FilterLogEvents"} in headers
  end

  test "HTTP failures preserve the ExAws error contract", %{config: config} do
    assert {:error, {:http_error, 403, _}} =
             "fixture-bucket" |> ExAws.S3.get_object("denied") |> ExAws.request(config)

    assert_receive {:fixture_request, "GET", "/fixture-bucket/denied", _, _}
    refute_receive {:fixture_request, _, _, _, _}
  end

  test "signed requests do not follow redirects implicitly", %{config: config} do
    assert {:error, {:http_error, 301, "redirected"}} =
             "fixture-bucket" |> ExAws.S3.get_object("redirect") |> ExAws.request(config)

    assert_receive {:fixture_request, "GET", "/fixture-bucket/redirect", _, _}
    refute_receive {:fixture_request, _, "/fixture-bucket/must-not-follow", _, _}
  end

  @tag storage: true
  test "Storage preserves image, PDF and HTML MIME types through Req lowercase headers" do
    for {extension, mime} <- [
          {"png", "image/png"},
          {"pdf", "application/pdf"},
          {"html", "text/html"}
        ] do
      assert Mokaid.Storage.get_object("mime/#{extension}") ==
               {:ok, "synthetic #{extension} fixture", mime}
    end
  end

  @tag storage: true
  test "Storage preserves transport errors instead of returning a default object" do
    assert {:error, {:http_error, 403, _}} = Mokaid.Storage.get_object("denied")
  end

  defp replace_env(app, key, value) do
    previous = Application.fetch_env(app, key)

    on_exit(fn ->
      case previous do
        {:ok, original} -> Application.put_env(app, key, original)
        :error -> Application.delete_env(app, key)
      end
    end)

    Application.put_env(app, key, value)
  end
end
