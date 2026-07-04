defmodule MokaidWeb.Plugs.Authenticate do
  @moduledoc """
  Authenticates requests via Bearer token.
  - `:cognito` mode validates Cognito JWTs through JWKS and maps `sub`.
  - `:dev_fallback` mode verifies Phoenix-signed session tokens.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Mokaid.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- resolve_user(token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Invalid or missing token"}})
        |> halt()
    end
  end

  defp resolve_user(token) do
    case Application.fetch_env!(:mokaid, :auth)[:mode] do
      :cognito ->
        with {:ok, claims} <- Mokaid.Auth.Cognito.verify_token(token) do
          Accounts.upsert_from_cognito(claims)
        end

      :dev_fallback ->
        with {:ok, user_id} <- Mokaid.Auth.Token.verify(token),
             %{} = user <- Accounts.get_user(user_id) do
          {:ok, user}
        else
          nil -> {:error, :not_found}
          error -> error
        end
    end
  end
end
