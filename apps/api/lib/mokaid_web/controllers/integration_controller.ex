defmodule MokaidWeb.IntegrationController do
  use MokaidWeb, :controller

  alias Mokaid.Integrations
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.view") do
      providers = Integrations.list_providers()
      connections = Integrations.list_connections(workspace_id(conn))

      json(conn, %{
        data: %{
          providers: Enum.map(providers, &Serializer.integration_provider/1),
          connections: Enum.map(connections, &Serializer.integration_connection/1)
        }
      })
    end
  end

  def connect(conn, %{"provider" => provider_key}) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, connection} <-
           Integrations.connect(workspace_id(conn), provider_key, current_member(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.integration_connection(connection)})
    else
      {:error, :oauth_required} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            code: "oauth_required",
            message:
              "This integration requires OAuth. Use /integrations/google/oauth/start, /integrations/github/oauth/start, /integrations/linear/oauth/start, or /integrations/slack/oauth/start."
          }
        })
    end
  end

  def disconnect(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.disconnect"),
         %{} = connection <- Integrations.get_connection(workspace_id(conn), id),
         {:ok, updated} <- Integrations.disconnect(connection, current_member(conn)) do
      json(conn, %{
        data: Serializer.integration_connection(Mokaid.Repo.preload(updated, :provider))
      })
    end
  end

  @doc """
  Serves the official integration logo (S3, with bundled priv fallback).
  Public catalog asset (no auth).
  """
  def logo(conn, %{"key" => key}) do
    with %{} = provider <- Integrations.get_provider_by_key(key),
         {:ok, body, content_type} <- Mokaid.Integrations.LogoAssets.fetch_for(provider) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "public, max-age=3600, must-revalidate")
      |> send_resp(200, body)
    else
      _ ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "Logo not found"}})
    end
  end
end
