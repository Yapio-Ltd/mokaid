defmodule MokaidWeb.RuntimeWebhookController do
  use MokaidWeb, :controller

  @headers ~w(webhook-id webhook-signature webhook-timestamp)

  def notify(conn, _params) do
    headers = Enum.map(@headers, &{&1, get_req_header(conn, &1)})
    body = conn.assigns[:raw_body]

    if is_binary(body) and
         Enum.all?(headers, fn {_key, values} ->
           match?([value] when is_binary(value) and byte_size(value) in 1..1024, values)
         end) do
      headers = Enum.map(headers, fn {key, [value]} -> {key, value} end)
      relay(conn, body, headers)
    else
      send_resp(conn, :bad_request, "")
    end
  end

  defp relay(conn, body, headers) do
    config = Application.get_env(:mokaid, :ai_worker, [])
    url = config[:url]
    uri = if is_binary(url), do: URI.parse(url)

    if uri && uri.scheme in ["http", "https"] && is_binary(uri.host) do
      opts = [
        url: String.trim_trailing(url, "/") <> "/webhooks/openai/agents",
        body: body,
        headers: [{"content-type", "application/json"} | headers],
        connect_options: [timeout: 1_000],
        receive_timeout: 5_000,
        retry: false,
        redirect: false,
        decode_body: false
      ]

      # Request options are deployment/test configuration, never request input.
      opts = Keyword.merge(opts, Application.get_env(:mokaid, :runtime_webhook_http_options, []))

      case Req.post(opts) do
        {:ok, %{status: status}} when status in 200..299 ->
          send_resp(conn, :accepted, "")

        {:ok, %{status: status}} when status in [400, 401, 403, 409, 422] ->
          send_resp(conn, :bad_request, "")

        {:ok, %{status: 413}} ->
          send_resp(conn, :request_entity_too_large, "")

        _ ->
          # Provider retries are required until the worker verifies and durably
          # persists the event. Never acknowledge a failed forwarding attempt.
          send_resp(conn, :service_unavailable, "")
      end
    else
      send_resp(conn, :service_unavailable, "")
    end
  end
end
