defmodule MokaidWeb.CacheBodyReader do
  @moduledoc """
  Preserves the raw request body on `conn.assigns[:raw_body]` so webhook
  signature verification (Stripe) can hash the exact bytes Stripe signed.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)
    {:ok, body, conn}
  end
end
