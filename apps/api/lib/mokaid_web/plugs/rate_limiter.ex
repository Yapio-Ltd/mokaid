defmodule MokaidWeb.Plugs.RateLimiter do
  @moduledoc "Simple per-IP rate limiting using Hammer."

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @limit 300
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case Hammer.check_rate("api:#{ip}", @window_ms, @limit) do
      {:allow, _count} ->
        conn

      {:deny, _limit} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: %{code: "rate_limited", message: "Too many requests"}})
        |> halt()
    end
  end
end
