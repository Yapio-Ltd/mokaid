defmodule MokaidWeb.Plugs.RuntimeWebhookBody do
  @moduledoc "Bounds and preserves the signed Agents webhook before general request parsing."
  import Plug.Conn

  @max_bytes 1_048_576

  def init(opts), do: opts

  def call(%{method: "POST", request_path: "/api/webhooks/openai/agents"} = conn, _opts) do
    content_type = get_req_header(conn, "content-type") |> List.first("")

    if String.starts_with?(content_type, "application/json") do
      case MokaidWeb.CacheBodyReader.read_body(conn,
             length: @max_bytes,
             read_length: 64_000,
             read_timeout: 2_000
           ) do
        {:ok, body, conn} when byte_size(body) <= @max_bytes ->
          # Signature validation belongs to the worker SDK. Do not decode or
          # re-encode the envelope before forwarding its exact signed bytes.
          %{conn | body_params: %{}}

        {:more, _, conn} ->
          reject(conn, 413)

        {:ok, _, conn} ->
          reject(conn, 413)

        {:error, _} ->
          reject(conn, 400)
      end
    else
      reject(conn, 415)
    end
  end

  def call(conn, _opts), do: conn
  defp reject(conn, status), do: conn |> send_resp(status, "") |> halt()
end
