defmodule MokaidWeb.RuntimeWebhookControllerTest do
  use MokaidWeb.ConnCase, async: false

  @path "/api/webhooks/openai/agents"

  setup %{conn: conn} do
    previous = Application.get_env(:mokaid, :ai_worker)
    previous_options = Application.get_env(:mokaid, :runtime_webhook_http_options)
    Application.put_env(:mokaid, :ai_worker, url: "http://worker.private:8100", dispatch: :sqs)
    Application.put_env(:mokaid, :runtime_webhook_http_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:mokaid, :ai_worker, previous)

      if previous_options,
        do: Application.put_env(:mokaid, :runtime_webhook_http_options, previous_options),
        else: Application.delete_env(:mokaid, :runtime_webhook_http_options)
    end)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("webhook-id", "event-1")
      |> put_req_header("webhook-signature", "v1,signed-bytes")
      |> put_req_header("webhook-timestamp", "1234567890")
      |> put_req_header("authorization", "Bearer unrelated-client-token")

    %{conn: conn}
  end

  test "relays exact bytes and only signature headers to private worker even in SQS mode", c do
    body = "{\n  \"id\": \"event-1\", \"text\": \"é\"\n}\n"

    Req.Test.stub(__MODULE__, fn request ->
      assert request.host == "worker.private"
      assert request.request_path == "/webhooks/openai/agents"
      assert get_req_header(request, "webhook-id") == ["event-1"]
      assert get_req_header(request, "webhook-signature") == ["v1,signed-bytes"]
      assert get_req_header(request, "webhook-timestamp") == ["1234567890"]
      assert get_req_header(request, "authorization") == []
      assert {:ok, ^body, request} = Plug.Conn.read_body(request)
      Plug.Conn.send_resp(request, 202, "{}")
    end)

    assert post(c.conn, @path, body) |> response(202) == ""
  end

  test "signature rejection remains 400 while persistence or forwarding errors request retry",
       c do
    for {worker_status, expected} <- [{400, 400}, {503, 503}, {500, 503}] do
      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, worker_status, "{}"))
      assert post(c.conn, @path, "{}") |> response(expected) == ""
    end

    Application.put_env(:mokaid, :ai_worker, dispatch: :sqs)
    assert post(c.conn, @path, "{}") |> response(503) == ""
  end

  test "rejects missing signature or oversized body before forwarding", c do
    Req.Test.stub(__MODULE__, fn _ -> flunk("Rejected webhook must not be forwarded") end)

    assert c.conn |> delete_req_header("webhook-signature") |> post(@path, "{}") |> response(400) ==
             ""

    assert post(c.conn, @path, String.duplicate("x", 1_048_577)) |> response(413) == ""

    assert c.conn
           |> put_req_header("content-type", "multipart/form-data")
           |> post(@path, "{}")
           |> response(415) == ""
  end
end
