defmodule MokaidWeb.Plugs.BrowserSession do
  @moduledoc "Encrypted HttpOnly browser credentials, with Origin and CSRF protection."
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @login_paths ~w(/api/auth/login /api/auth/register /api/auth/google/start /api/auth/google/callback)
  @marker "browser:"

  def init(opts), do: opts

  def call(conn, _) do
    conn = fetch_session(conn)

    cookie_login? =
      conn.request_path in @login_paths and conn.params["session_transport"] == "cookie"

    cookie_mutation? =
      conn.method not in ["GET", "HEAD", "OPTIONS"] and
        is_binary(get_session(conn, :web_token)) and get_req_header(conn, "authorization") == [] and
        not cookie_login?

    cond do
      cookie_login? and not trusted_origin?(conn) -> reject(conn)
      cookie_mutation? and (not trusted_origin?(conn) or not valid_csrf?(conn)) -> reject(conn)
      true -> conn
    end
  end

  # Return only a non-credential CSRF marker to JavaScript. The actual session
  # credential is encrypted, HttpOnly, same-site, and revocable in the database.
  def issue(conn, token, params) do
    if params["session_transport"] == "cookie" or conn.assigns[:auth_transport] == :cookie do
      Mokaid.Auth.Token.revoke(token(conn))
      Plug.CSRFProtection.load_state(conn.secret_key_base, nil)
      csrf = Plug.CSRFProtection.get_csrf_token()
      state = Plug.CSRFProtection.dump_state()
      Plug.CSRFProtection.delete_csrf_token()

      conn =
        conn
        |> clear_session()
        |> configure_session(renew: true)
        |> put_session(:web_token, token)
        |> put_session(:_csrf_token, state)

      {conn, @marker <> csrf}
    else
      {conn, token}
    end
  end

  def token(conn), do: get_session(conn, :web_token)
  def clear(conn), do: conn |> clear_session() |> configure_session(drop: true)

  defp valid_csrf?(conn) do
    case get_req_header(conn, "x-csrf-token") do
      [csrf] ->
        Plug.CSRFProtection.valid_state_and_csrf_token?(get_session(conn, :_csrf_token), csrf)

      _ ->
        false
    end
  end

  defp trusted_origin?(conn) do
    allowed = [
      MokaidWeb.Endpoint.url(),
      Application.get_env(:mokaid, :desktop_auth, [])[:web_base_url] || "https://mokaid.com"
      | Application.get_env(:mokaid, :cors_origins, [])
    ]

    case get_req_header(conn, "origin") do
      [origin] -> origin in Enum.map(allowed, &String.trim_trailing(&1, "/"))
      _ -> false
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(:forbidden)
    |> json(%{error: %{code: "invalid_csrf", message: "Refresh the page and try again."}})
    |> halt()
  end
end
