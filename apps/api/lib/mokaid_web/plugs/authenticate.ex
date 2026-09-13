defmodule MokaidWeb.Plugs.Authenticate do
  @moduledoc """
  Authenticates requests via Bearer token.
  - `:cognito` mode validates Cognito JWTs through JWKS and maps `sub`.
  - `:dev_fallback` mode verifies Phoenix-signed session tokens.
  Blocks suspended/disabled/banned/anonymized users.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user, metadata} <- Mokaid.Auth.Session.authenticate(token) do
      conn |> assign(:current_user, user) |> assign(:auth_session, metadata)
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
