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
    end
  end

  def disconnect(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "integrations.disconnect"),
         %{} = connection <- Integrations.get_connection(workspace_id(conn), id),
         {:ok, updated} <- Integrations.disconnect(connection, current_member(conn)) do
      json(conn, %{data: Serializer.integration_connection(Mokaid.Repo.preload(updated, :provider))})
    end
  end
end
