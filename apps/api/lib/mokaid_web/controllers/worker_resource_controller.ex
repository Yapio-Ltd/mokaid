defmodule MokaidWeb.WorkerResourceController do
  @moduledoc """
  Workspace resources exposed to the AI worker: semantic knowledge search,
  chunk storage after embedding, and task mutations performed by agents.
  """

  use MokaidWeb, :controller

  alias Mokaid.Agents
  alias Mokaid.Knowledge
  alias Mokaid.Tasks

  def search_knowledge(conn, %{"workspace_id" => workspace_id, "embedding" => embedding} = params) do
    limit = min(params["limit"] || 5, 20)
    results = Knowledge.search_chunks(workspace_id, embedding, limit)

    json(conn, %{
      data:
        Enum.map(results, fn %{chunk: chunk, item_title: title, distance: distance} ->
          %{
            knowledge_item_id: chunk.knowledge_item_id,
            title: title,
            content: chunk.content,
            chunk_index: chunk.chunk_index,
            score: 1.0 - distance
          }
        end)
    })
  end

  def knowledge_chunks(conn, %{"id" => id, "workspace_id" => workspace_id, "chunks" => chunks}) do
    with %{} = item <- Knowledge.get_item(workspace_id, id) do
      entries =
        Enum.map(chunks, fn chunk ->
          %{
            content: chunk["content"],
            embedding: chunk["embedding"],
            metadata: chunk["metadata"] || %{}
          }
        end)

      {count, _} = Knowledge.replace_chunks(item, entries)
      {:ok, _item} = Knowledge.mark_indexed(item)

      json(conn, %{data: %{knowledge_item_id: item.id, chunk_count: count}})
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "knowledge item not found"}})
    end
  end

  def update_task(conn, %{"id" => id, "workspace_id" => workspace_id} = params) do
    attrs = Map.take(params, ["status", "progress_percent", "description"])

    with %{} = task <- Tasks.get_task(workspace_id, id),
         {:ok, updated} <- Tasks.update_task(task, attrs) do
      json(conn, %{
        data: %{
          id: updated.id,
          status: updated.status,
          progress_percent: updated.progress_percent
        }
      })
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "task not found"}})

      error ->
        error
    end
  end

  @doc """
  Posts a comment on a task as an agent (used for the conversational
  acknowledgement when a run starts). Broadcast in realtime by the context.
  """
  def create_comment(conn, %{"id" => id, "workspace_id" => workspace_id, "body" => body} = params) do
    with %{} = task <- Tasks.get_task(workspace_id, id) do
      agent =
        case params["agent_id"] || task.assigned_agent_id do
          nil -> nil
          agent_id -> Agents.get_agent(workspace_id, agent_id)
        end

      case Tasks.create_comment(task, %{"body" => body}, agent) do
        {:ok, comment} ->
          conn
          |> put_status(:created)
          |> json(%{data: %{id: comment.id, task_id: task.id}})

        error ->
          error
      end
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "task not found"}})
    end
  end

  def create_subtasks(conn, %{"id" => id, "workspace_id" => workspace_id, "subtasks" => subtasks}) do
    with %{} = task <- Tasks.get_task(workspace_id, id) do
      created =
        subtasks
        |> Enum.with_index()
        |> Enum.flat_map(fn {attrs, index} ->
          case Tasks.create_subtask(task, %{"title" => attrs["title"], "position" => index}) do
            {:ok, subtask} -> [%{id: subtask.id, title: subtask.title}]
            {:error, _} -> []
          end
        end)

      conn
      |> put_status(:created)
      |> json(%{data: created})
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "task not found"}})
    end
  end
end
