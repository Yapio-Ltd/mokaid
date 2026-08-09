defmodule MokaidWeb.KnowledgeController do
  use MokaidWeb, :controller

  import Ecto.Query

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

  @doc """
  Multipart file upload into the knowledge base. Each file is stored
  (S3/MinIO) and indexed: text formats inline, binary formats (PDF, DOCX,
  XLSX, PPTX…) asynchronously via the AI worker's extractors. Falls back to
  a plain JSON create when no file is attached.
  """
  def upload(conn, params) do
    uploads =
      List.wrap(params["files"] || params["file"])
      |> Enum.filter(&match?(%Plug.Upload{}, &1))

    if uploads == [] do
      create(conn, params)
    else
      with :ok <- Permissions.authorize(current_member(conn), "knowledge.upload") do
        items =
          uploads
          |> Enum.flat_map(fn upload ->
            case Knowledge.create_from_upload(
                   workspace_id(conn),
                   upload,
                   current_member(conn),
                   agent_id: presence(params["agent_id"]),
                   project_id: presence(params["project_id"]),
                   category_id: presence(params["category_id"])
                 ) do
              {:ok, item} -> [Serializer.knowledge_item(item)]
              _ -> []
            end
          end)

        conn
        |> put_status(:created)
        |> json(%{data: items})
      end
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  def show(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.view"),
         %{} = item <- Knowledge.get_item(workspace_id(conn), id) do
      # The full body only ships on the detail endpoint — lists stay light.
      json(conn, %{data: item |> Serializer.knowledge_item() |> Map.put(:body, item.body)})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.update"),
         %{} = item <- Knowledge.get_item(workspace_id(conn), id),
         {:ok, _} <- Knowledge.delete_item(item) do
      json(conn, %{ok: true})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.update"),
         %{} = item <- Knowledge.get_item(workspace_id(conn), id),
         {:ok, updated} <- Knowledge.update_item(item, params) do
      json(conn, %{data: Serializer.knowledge_item(updated)})
    end
  end

  def graph(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.view") do
      snapshot =
        Mokaid.Knowledge.Graph.snapshot(workspace_id(conn),
          project_id: presence(params["project_id"]),
          agent_id: presence(params["agent_id"])
        )

      json(conn, %{data: snapshot})
    end
  end

  def rebuild_graph(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.update"),
         true <- Mokaid.Knowledge.Graph.enabled?(workspace_id(conn)) || :upgrade_required,
         {:ok, count} <-
           Mokaid.Knowledge.Graph.rebuild_communities(workspace_id(conn),
             project_id: presence(params["project_id"]),
             agent_id: presence(params["agent_id"])
           ) do
      json(conn, %{data: %{communities: count}})
    else
      :upgrade_required ->
        conn
        |> put_status(:payment_required)
        |> json(%{
          error: %{
            code: "knowledge_graph_locked",
            message: "Knowledge Graph requires Starter or Professional"
          }
        })

      other ->
        other
    end
  end

  @doc """
  Charges credits and re-enqueues ingestion for published items so the graph
  is rebuilt (semantic extract + communities).
  """
  def reindex_graph(conn, params) do
    ws = workspace_id(conn)
    credits = Mokaid.Knowledge.Graph.reindex_credits()

    with :ok <- Permissions.authorize(current_member(conn), "knowledge.update"),
         true <- Mokaid.Knowledge.Graph.enabled?(ws) || :upgrade_required do
      charge =
        Mokaid.Repo.transaction(fn ->
          case Mokaid.Billing.Credits.charge_strict(ws, credits,
                 kind: "graph_reindex",
                 description: "Knowledge graph re-index"
               ) do
            {:ok, _sub, charged} -> charged
            {:error, reason} -> Mokaid.Repo.rollback(reason)
          end
        end)

      case charge do
        {:ok, ^credits} ->
          Mokaid.Billing.Credits.broadcast_balance(ws)

          items =
            Knowledge.list_items(ws, %{
              "status" => "published",
              "project_id" => presence(params["project_id"]),
              "agent_id" => presence(params["agent_id"])
            })

          Enum.each(items, fn item ->
            %{knowledge_item_id: item.id, workspace_id: ws}
            |> Mokaid.Knowledge.Workers.IngestionWorker.new()
            |> Oban.insert()
          end)

          Mokaid.Knowledge.Graph.rebuild_communities(ws,
            project_id: presence(params["project_id"]),
            agent_id: presence(params["agent_id"])
          )

          json(conn, %{
            data: %{
              requeued: length(items),
              credits_charged: credits
            }
          })

        {:error, :insufficient_credits} ->
          conn
          |> put_status(:payment_required)
          |> json(%{error: %{code: "insufficient_credits", message: "Not enough credits"}})

        other ->
          other
      end
    else
      :upgrade_required ->
        conn
        |> put_status(:payment_required)
        |> json(%{
          error: %{
            code: "knowledge_graph_locked",
            message: "Knowledge Graph requires Starter or Professional"
          }
        })

      other ->
        other
    end
  end

  def reflect(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.view") do
      data =
        Mokaid.Knowledge.Graph.reflect(workspace_id(conn), presence(params["agent_id"]))

      json(conn, %{data: data})
    end
  end

  @doc "Onboarding wizard: snapshot + suggested questions after bulk upload."
  def company_brain(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.view") do
      ws = workspace_id(conn)

      if Mokaid.Knowledge.Graph.enabled?(ws) do
        Mokaid.Knowledge.Graph.rebuild_communities(ws)
      end

      snapshot = Mokaid.Knowledge.Graph.snapshot(ws)

      report = %{
        title: "Company brain",
        god_concepts: snapshot.god_nodes,
        communities: snapshot.communities,
        suggested_questions: snapshot.suggested_questions,
        node_count: snapshot.node_count,
        edge_count: snapshot.edge_count,
        enabled: snapshot.enabled,
        upgrade_hint:
          if(snapshot.enabled,
            do: nil,
            else: "Upgrade to Starter to unlock the Knowledge Graph"
          )
      }

      # Optional: accept a batch of note bodies to seed as knowledge items.
      seeded =
        params
        |> Map.get("notes", [])
        |> List.wrap()
        |> Enum.take(20)
        |> Enum.flat_map(fn note ->
          title = note["title"] || "Company note"
          body = note["body"] || note["content"] || ""

          if body != "" do
            case Knowledge.create_item(
                   ws,
                   %{
                     "title" => title,
                     "type" => "note",
                     "body" => body,
                     "status" => "published",
                     "tags" => ["company-brain"]
                   },
                   current_member(conn)
                 ) do
              {:ok, item} -> [Serializer.knowledge_item(item)]
              _ -> []
            end
          else
            []
          end
        end)

      json(conn, %{data: Map.put(report, :seeded, seeded)})
    end
  end

  def office_zones(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "knowledge.view") do
      communities =
        from(c in Mokaid.Knowledge.KnowledgeCommunity,
          where: c.workspace_id == ^workspace_id(conn),
          where: not is_nil(c.office_zone),
          order_by: [desc: c.god_score]
        )
        |> Mokaid.Repo.all()
        |> Enum.map(&Mokaid.Knowledge.Graph.community_json/1)

      json(conn, %{data: communities})
    end
  end
end
