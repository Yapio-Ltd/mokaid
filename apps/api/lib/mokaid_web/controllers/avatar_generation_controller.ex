defmodule MokaidWeb.AvatarGenerationController do
  use MokaidWeb, :controller
  alias Mokaid.Avatars

  def index(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view") do
      json(conn, %{data: Enum.map(Avatars.list(workspace_id(conn)), &Avatars.serialize/1)})
    end
  end

  def show(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = generation <- Avatars.get(workspace_id(conn), id) do
      json(conn, %{data: Avatars.serialize(generation)})
    end
  end

  def create(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.create"),
         {:ok, generation} <- Avatars.create(workspace_id(conn), current_member(conn), params) do
      conn |> put_status(:accepted) |> json(%{data: Avatars.serialize(generation)})
    end
  end
end
