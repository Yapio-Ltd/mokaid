defmodule MokaidWeb.Plugs.Authenticate do
  @moduledoc """
  Authenticates requests via Bearer token or encrypted browser cookie.
  - `:cognito` mode validates Cognito JWTs through JWKS and maps `sub`.
  - `:dev_fallback` mode verifies opaque, revocable session credentials.
  Blocks suspended/disabled/banned/anonymized users.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    {token, transport} =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token] -> {token, :bearer}
        [] -> {MokaidWeb.Plugs.BrowserSession.token(conn), :cookie}
        _ -> {nil, :bearer}
      end

    with {:ok, user, metadata} <- Mokaid.Auth.Session.authenticate(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:auth_session, metadata)
      |> assign(:auth_transport, transport)
    else
      {:error, :inactive} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: %{
            code: "account_inactive",
            message: "Account is suspended, banned, or scheduled for deletion"
          }
        })
        |> halt()

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Invalid or missing token"}})
        |> halt()
    end
  end
end
