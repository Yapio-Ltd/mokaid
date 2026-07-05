defmodule MokaidWeb.MCPOAuthController do
  @moduledoc """
  OAuth flows for MCP servers. Figma: `start` returns the consent URL with a
  signed state; `callback` exchanges the code, stores the encrypted token on
  the workspace's Figma installation and marks it connected.
  """

  use MokaidWeb, :controller

  alias Mokaid.MCP
  alias Mokaid.MCP.FigmaOAuth
  alias MokaidWeb.JSON, as: Serializer

  def figma_start(conn, params) do
    redirect_uri = params["redirect_uri"] || default_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, url} <-
           FigmaOAuth.authorize_url(workspace_id(conn), current_member(conn).id, redirect_uri) do
      json(conn, %{data: %{authorize_url: url}})
    else
      {:error, :oauth_not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{
            code: "oauth_not_configured",
            message: "Figma OAuth is not configured on this environment"
          }
        })

      other ->
        other
    end
  end

  def figma_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_uri = params["redirect_uri"] || default_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, result} <- FigmaOAuth.exchange_code(code, state, redirect_uri),
         :ok <- ensure_same_workspace(conn, result.workspace_id),
         {:ok, installation} <-
           MCP.install(workspace_id(conn), "figma", current_member(conn), %{}),
         {:ok, updated} <-
           MCP.store_credentials(installation, result.credentials, result.account) do
      json(conn, %{data: Serializer.mcp_installation(%{updated | server: installation.server})})
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
            message: "Figma rejected the authorization code"
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
    Application.get_env(:mokaid, :figma_oauth, [])
    |> Keyword.get(:redirect_uris, [])
    |> List.first()
  end
end
