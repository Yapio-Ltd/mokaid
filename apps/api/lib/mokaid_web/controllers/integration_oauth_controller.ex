defmodule MokaidWeb.IntegrationOAuthController do
  @moduledoc """
  OAuth flows for workspace integrations (Google Drive, Gmail, Calendar…).
  """

  use MokaidWeb, :controller

  alias Mokaid.Integrations
  alias Mokaid.Integrations.GoogleOAuth
  alias MokaidWeb.JSON, as: Serializer

  def google_start(conn, params) do
    redirect_uri = params["redirect_uri"] || default_redirect_uri()
    provider_key = params["provider_key"] || "google_drive"

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, url} <-
           GoogleOAuth.authorize_url(
             workspace_id(conn),
             current_member(conn).id,
             redirect_uri,
             provider_key
           ) do
      json(conn, %{data: %{authorize_url: url}})
    else
      {:error, :oauth_not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{
            code: "oauth_not_configured",
            message: "Google OAuth is not configured on this environment"
          }
        })

      other ->
        other
    end
  end

  def google_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_uri = params["redirect_uri"] || default_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, result} <- GoogleOAuth.exchange_code(code, state, redirect_uri),
         :ok <- ensure_same_workspace(conn, result.workspace_id),
         {:ok, connections} <-
           Integrations.connect_google_providers(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ),
         {:ok, _} <- Integrations.sync_google_mcp_installations(result.workspace_id, current_member(conn), result.credentials, result.account) do
      json(conn, %{
        data: %{
          connections: Enum.map(connections, &Serializer.integration_connection/1),
          connected_account: result.account,
          provider_key: result.provider_key
        }
      })
    else
      {:error, :invalid_state} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_state", message: "OAuth state is invalid or expired"}})

      {:error, {:token_exchange_failed, _status, _detail}} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{
          error: %{
            code: "token_exchange_failed",
            message: "Google rejected the authorization code"
          }
        })

      other ->
        other
    end
  end

  defp ensure_same_workspace(conn, state_workspace_id) do
    if workspace_id(conn) == state_workspace_id, do: :ok, else: {:error, :forbidden}
  end

  defp default_redirect_uri do
    Application.get_env(:mokaid, :google_oauth, [])
    |> Keyword.get(:redirect_uris, [])
    |> List.first()
  end
end
