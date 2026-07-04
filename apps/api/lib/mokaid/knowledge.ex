defmodule Mokaid.Knowledge do
  @moduledoc "Curated knowledge that AI agents may use, with permission controls."

  import Ecto.Query

  alias Mokaid.Knowledge.{KnowledgeCategory, KnowledgeChunk, KnowledgeItem}
  alias Mokaid.Realtime
  alias Mokaid.Repo

  def list_categories(workspace_id) do
    Repo.all(
      from c in KnowledgeCategory,
        where: c.workspace_id == ^workspace_id,
        order_by: [asc: c.position, asc: c.name],
        preload: [:items]
    )
  end

  def create_category(workspace_id, attrs) do
    %KnowledgeCategory{}
    |> KnowledgeCategory.changeset(Map.put(attrs, "workspace_id", workspace_id))
    |> Repo.insert()
  end

  def get_item(workspace_id, id) do
    Repo.one(
      from i in KnowledgeItem,
        where: i.workspace_id == ^workspace_id and i.id == ^id,
        preload: [:category, created_by_member: :user]
    )
  end

  def list_items(workspace_id, filters \\ %{}) do
    from(i in KnowledgeItem,
      where: i.workspace_id == ^workspace_id,
      preload: [:category, created_by_member: :user],
      order_by: [desc: i.updated_at]
    )
    |> maybe_filter(:category_id, filters["category_id"])
    |> maybe_filter(:type, filters["type"])
    |> maybe_filter(:status, filters["status"])
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [i], field(i, ^field) == ^value)

  def create_item(workspace_id, attrs, created_by \\ nil) do
    result =
      %KnowledgeItem{}
      |> KnowledgeItem.changeset(
        Map.merge(attrs, %{
          "workspace_id" => workspace_id,
          "created_by_member_id" => created_by && created_by.id
        })
      )
      |> Repo.insert()

    with {:ok, item} <- result do
      Realtime.broadcast_workspace(workspace_id, "knowledge.uploaded", %{item_id: item.id})
      {:ok, Repo.preload(item, [:category, created_by_member: :user])}
    end
  end

  def update_item(%KnowledgeItem{} = item, attrs) do
    item
    |> KnowledgeItem.changeset(Map.put(attrs, "workspace_id", item.workspace_id))
    |> Repo.update()
  end

  def mark_indexed(%KnowledgeItem{} = item) do
    result =
      item
      |> Ecto.Changeset.change(indexing_status: "indexed", status: "published")
      |> Repo.update()

    with {:ok, updated} <- result do
      Realtime.broadcast_workspace(item.workspace_id, "knowledge.indexed", %{item_id: item.id})
      {:ok, updated}
    end
  end

  def insert_chunks(%KnowledgeItem{} = item, chunks) do
    now = DateTime.utc_now()

    entries =
      chunks
      |> Enum.with_index()
      |> Enum.map(fn {%{content: content} = chunk, index} ->
        %{
          id: Ecto.UUID.generate(),
          workspace_id: item.workspace_id,
          knowledge_item_id: item.id,
          chunk_index: index,
          content: content,
          embedding: chunk[:embedding],
          metadata: chunk[:metadata] || %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(KnowledgeChunk, entries)
  end

  def counts(workspace_id) do
    base = from i in KnowledgeItem, where: i.workspace_id == ^workspace_id

    %{
      total: Repo.aggregate(base, :count),
      documents: Repo.aggregate(where(base, [i], i.type == "document"), :count),
      links: Repo.aggregate(where(base, [i], i.type == "link"), :count),
      files: Repo.aggregate(where(base, [i], i.type == "file"), :count),
      notes: Repo.aggregate(where(base, [i], i.type == "note"), :count),
      categories:
        Repo.aggregate(
          from(c in KnowledgeCategory, where: c.workspace_id == ^workspace_id),
          :count
        )
    }
  end
end
