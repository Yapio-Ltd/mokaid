defmodule MokaidWeb.KnowledgeController do
  use MokaidWeb, :controller

  alias Mokaid.Knowledge
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.view") do
      items = Knowledge.list_items(workspace_id(conn), params)
      counts = Knowledge.counts(workspace_id(conn))

      json(conn, %{data: Enum.map(items, &Serializer.knowledge_item/1), meta: %{counts: counts}})
    end
  end

  def categories(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.view") do
      categories = Knowledge.list_categories(workspace_id(conn))
      json(conn, %{data: Enum.map(categories, &Serializer.knowledge_category/1)})
    end
  end

  def create(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.upload"),
         {:ok, item} <- Knowledge.create_item(workspace_id(conn), params, current_member(conn)) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.knowledge_item(item)})
    end
  end

  def upload(conn, params) do
    create(conn, params)
  end

  def show(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.view"),
         %{} = item <- Knowledge.get_item(workspace_id(conn), id) do
      json(conn, %{data: Serializer.knowledge_item(item)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.update"),
         %{} = item <- Knowledge.get_item(workspace_id(conn), id),
         {:ok, updated} <- Knowledge.update_item(item, params) do
      json(conn, %{data: Serializer.knowledge_item(updated)})
    end
  end
end
