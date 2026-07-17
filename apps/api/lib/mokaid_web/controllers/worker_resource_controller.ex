defmodule MokaidWeb.WorkerResourceController do
  @moduledoc """
  Workspace resources exposed to the AI worker: semantic knowledge search,
  chunk storage after embedding, and task mutations performed by agents.
  """

  use MokaidWeb, :controller

  alias Mokaid.Agents
  alias Mokaid.Drive
  alias Mokaid.Knowledge
  alias Mokaid.Realtime
  alias Mokaid.Tasks

  def search_knowledge(conn, %{"workspace_id" => workspace_id, "embedding" => embedding} = params) do
    limit = min(params["limit"] || 5, 20)

    # Three-level retrieval: general knowledge + the run's project + agent.
    # Hybrid: the raw query text feeds the lexical (full-text) branch.
    results =
      Knowledge.search_chunks(workspace_id, embedding, limit,
        project_id: presence(params["project_id"]),
        agent_id: presence(params["agent_id"]),
        query: params["query"]
      )

    json(conn, %{
      data:
        Enum.map(results, fn %{chunk: chunk, item_title: title, scope: scope} = result ->
          %{
            knowledge_item_id: chunk.knowledge_item_id,
            title: title,
            content: chunk.content,
            chunk_index: chunk.chunk_index,
            scope: scope,
            score: result.distance && 1.0 - result.distance,
            rrf_score: result.score
          }
        end)
    })
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  def knowledge_chunks(
        conn,
        %{"id" => id, "workspace_id" => workspace_id, "chunks" => chunks} = params
      ) do
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

      if params["graph"] && Mokaid.Knowledge.Graph.enabled?(workspace_id) do
        Mokaid.Knowledge.Graph.replace_item_graph(item, params["graph"])
      end

      {:ok, _item} = Knowledge.mark_indexed(item)

      json(conn, %{data: %{knowledge_item_id: item.id, chunk_count: count}})
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "knowledge item not found"}})
    end
  end

  def traverse_knowledge(conn, %{"workspace_id" => workspace_id, "query" => query} = params) do
    unless Mokaid.Knowledge.Graph.enabled?(workspace_id) do
      json(conn, %{data: %{nodes: [], edges: [], enabled: false}})
    else
      result =
        Mokaid.Knowledge.Graph.traverse(workspace_id, query,
          project_id: presence(params["project_id"]),
          agent_id: presence(params["agent_id"]),
          limit: min(params["limit"] || 40, 80),
          depth: min(params["depth"] || 2, 3)
        )

      json(conn, %{data: Map.put(result, :enabled, true)})
    end
  end

  def knowledge_path(conn, %{"workspace_id" => workspace_id, "from" => from, "to" => to} = params) do
    unless Mokaid.Knowledge.Graph.enabled?(workspace_id) do
      json(conn, %{data: %{path: [], hops: 0, enabled: false}})
    else
      result =
        Mokaid.Knowledge.Graph.shortest_path(workspace_id, from, to,
          project_id: presence(params["project_id"]),
          agent_id: presence(params["agent_id"])
        )

      json(conn, %{data: Map.put(result, :enabled, true)})
    end
  end

  def explain_concept(conn, %{"workspace_id" => workspace_id, "query" => query} = params) do
    unless Mokaid.Knowledge.Graph.enabled?(workspace_id) do
      json(conn, %{data: %{node: nil, connections: [], enabled: false}})
    else
      result =
        Mokaid.Knowledge.Graph.explain(workspace_id, query,
          project_id: presence(params["project_id"]),
          agent_id: presence(params["agent_id"])
        )

      json(conn, %{data: Map.put(result, :enabled, true)})
    end
  end

  def save_graph_outcome(conn, %{"workspace_id" => workspace_id} = params) do
    attrs = %{
      "agent_id" => presence(params["agent_id"]),
      "task_id" => presence(params["task_id"]),
      "question" => params["question"],
      "answer_summary" => params["answer_summary"],
      "outcome" => params["outcome"] || "useful",
      "node_ids" => List.wrap(params["node_ids"]),
      "metadata" => params["metadata"] || %{}
    }

    case Mokaid.Knowledge.Graph.save_outcome(workspace_id, attrs) do
      {:ok, outcome} ->
        conn
        |> put_status(:created)
        |> json(%{data: %{id: outcome.id, outcome: outcome.outcome}})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid", details: changeset.errors}})
    end
  end

  @doc "Marks a knowledge item's indexing as failed (unreadable/unsupported file)."
  def knowledge_failed(conn, %{"id" => id, "workspace_id" => workspace_id} = params) do
    with %{} = item <- Knowledge.get_item(workspace_id, id),
         {:ok, updated} <- Knowledge.mark_failed(item, params["error"]) do
      json(conn, %{data: %{knowledge_item_id: updated.id, indexing_status: "failed"}})
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "knowledge item not found"}})

      error ->
        error
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

  @doc """
  Posts the agent's reply in its direct chat thread (floating dock). The
  context broadcasts `agent_chat.message` so open docks update instantly.

  When the worker judged the member's message to be an actionable work
  request (`start_task: true`), it starts a task assigned to the agent
  instead of leaving it a plain reply — the run's output later lands back in
  this thread.
  """
  def agent_chat_message(conn, %{"id" => id, "workspace_id" => workspace_id} = params) do
    body = params["body"] || ""

    with %{} = agent <- Agents.get_agent(workspace_id, id),
         {:ok, message} <-
           Mokaid.AgentChat.post_agent_message(workspace_id, agent.id, body,
             stream_id: params["stream_id"]
           ) do
      maybe_start_chat_task(workspace_id, agent, params)

      conn
      |> put_status(:created)
      |> json(%{
        data: %{
          id: message.id,
          agent_id: agent.id,
          stream_id: params["stream_id"]
        }
      })
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "agent not found"}})

      error ->
        error
    end
  end

  @doc """
  Relays a live text delta of the agent's in-progress chat reply. Nothing is
  persisted here — the UI renders the growing draft (typewriter effect) and
  the complete message arrives separately via `agent_chat_message`.
  """
  def agent_chat_stream(conn, %{"id" => id, "workspace_id" => workspace_id} = params) do
    Mokaid.Realtime.broadcast_workspace(workspace_id, "agent_chat.chunk", %{
      agent_id: id,
      stream_id: params["stream_id"],
      chunk: params["chunk"] || "",
      done: params["done"] == true
    })

    json(conn, %{data: %{ok: true}})
  end

  # The worker asks us to start a task from a text-only chat request it judged
  # actionable. The member who initiated the thread is the task creator.
  # `skip_ack: true` is the default from the structured direct_chat path —
  # the personalized reply was already posted.
  defp maybe_start_chat_task(workspace_id, agent, %{"start_task" => true} = params) do
    instruction = params["instruction"] || params["body"] || ""
    member_id = params["member_id"]
    member = member_id && Mokaid.Members.get_member(workspace_id, member_id)
    language = params["language"]
    skip_ack? = params["skip_ack"] != false
    attachments = recover_attachments(workspace_id, params)

    if member && instruction != "" do
      pseudo_message = %Mokaid.AgentChat.ChatMessage{body: instruction, attachments: attachments}

      Mokaid.AgentChat.resume_or_start_chat_task(
        workspace_id,
        agent,
        member,
        pseudo_message,
        attachments,
        skip_ack: skip_ack?,
        language: language
      )
    else
      require Logger

      Logger.warning(
        "chat_start_task_skipped agent=#{agent.id} member=#{inspect(member_id)} instruction_empty=#{instruction == ""}"
      )
    end

    :ok
  end

  defp maybe_start_chat_task(_workspace_id, _agent, _params), do: :ok

  # Recover file attachments: prefer the ones forwarded by the worker, fall
  # back to looking up the original member message by ID.
  defp recover_attachments(workspace_id, params) do
    case params["attachments"] do
      [_ | _] = atts ->
        atts

      _ ->
        case params["message_id"] do
          id when is_binary(id) ->
            case Mokaid.Repo.get(Mokaid.AgentChat.ChatMessage, id) do
              %{workspace_id: ^workspace_id, attachments: atts} when is_list(atts) -> atts
              _ -> []
            end

          _ ->
            []
        end
    end
  end

  @doc """
  Stores a mission memory as agent-scoped knowledge. The ingestion pipeline
  vectorizes it, so the agent's future retrievals include what it learned —
  its expertise literally grows with every mission.
  """
  def agent_memory(
        conn,
        %{"id" => id, "workspace_id" => workspace_id, "title" => title, "content" => content}
      )
      when is_binary(content) and content != "" do
    with %{} = agent <- Agents.get_agent(workspace_id, id),
         {:ok, item} <-
           Mokaid.Knowledge.create_item(workspace_id, %{
             "title" => title || "Mission memory",
             "type" => "note",
             "body" => content,
             "agent_id" => agent.id,
             "status" => "published",
             "tags" => ["mission-memory"]
           }) do
      conn
      |> put_status(:created)
      |> json(%{data: %{id: item.id, agent_id: agent.id}})
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "agent not found"}})

      error ->
        error
    end
  end

  @doc """
  Saves a file produced by an agent (draft, report, transformed asset…) into
  the Drive, linked to the task, so users can see and download the output.
  Content is plain text by default; pass "encoding": "base64" for binaries.
  """
  def save_output(
        conn,
        %{
          "id" => id,
          "workspace_id" => workspace_id,
          "filename" => filename,
          "content" => content
        } =
          params
      ) do
    with %{} = task <- Tasks.get_task(workspace_id, id),
         {:ok, binary} <- decode_content(content, params["encoding"]),
         {:ok, stored} <-
           Mokaid.Storage.upload_content(workspace_id, filename, binary, params["mime_type"]) do
      agent = task.assigned_agent_id && Agents.get_agent(workspace_id, task.assigned_agent_id)
      outputs_folder = Drive.ensure_system_folder(workspace_id, "Agent Outputs")

      case Drive.create_file(
             workspace_id,
             %{
               "name" => filename,
               "parent_id" => outputs_folder.id,
               "mime_type" => params["mime_type"],
               "extension" => file_extension(filename),
               "size_bytes" => stored.size_bytes,
               "storage_key" => stored.storage_key,
               "checksum" => stored.checksum,
               "linked_task_id" => task.id,
               "linked_project_id" => task.project_id,
               "is_ai_readable" => true
             },
             agent
           ) do
        {:ok, item} ->
          Realtime.broadcast_workspace(workspace_id, "task.updated", %{task_id: task.id})

          conn
          |> put_status(:created)
          |> json(%{data: %{id: item.id, name: item.name, task_id: task.id}})

        error ->
          error
      end
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found", message: "task not found"}})

      {:error, :invalid_encoding} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_encoding", message: "content could not be decoded"}})

      error ->
        error
    end
  end

  defp decode_content(content, "base64") when is_binary(content) do
    case Base.decode64(content) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, :invalid_encoding}
    end
  end

  defp decode_content(content, _encoding) when is_binary(content), do: {:ok, content}
  defp decode_content(_content, _encoding), do: {:error, :invalid_encoding}

  defp file_extension(filename) do
    case Path.extname(filename) do
      "." <> ext -> String.downcase(ext)
      _ -> nil
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
