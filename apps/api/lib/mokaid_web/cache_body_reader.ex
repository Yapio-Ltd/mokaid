defmodule MokaidWeb.CacheBodyReader do
  @moduledoc """
  Preserves the raw request body on `conn.assigns[:raw_body]` so webhook
  signature verification (Stripe) can hash the exact bytes Stripe signed.
  """

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        conn = Plug.Conn.assign(conn, :raw_body, (conn.assigns[:raw_body] || "") <> body)
        {status, body, conn}

      error ->
        error
    end
  end
end
