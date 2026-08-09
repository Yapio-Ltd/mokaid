defmodule Mokaid.Knowledge do
  @moduledoc "Curated knowledge that AI agents may use, with permission controls."

  import Ecto.Query
  import Pgvector.Ecto.Query

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
    |> maybe_filter(:project_id, filters["project_id"])
    |> maybe_filter(:agent_id, filters["agent_id"])
    |> maybe_scope(filters["scope"])
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [i], field(i, ^field) == ^value)

  # "general" restricts to workspace-wide knowledge (no project, no agent).
  defp maybe_scope(query, "general"),
    do: where(query, [i], is_nil(i.project_id) and is_nil(i.agent_id))

  defp maybe_scope(query, _), do: query

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
      safe_enqueue_ingestion(item)
      {:ok, Repo.preload(item, [:category, created_by_member: :user])}
    end
  end

  @doc """
  Creates a knowledge item from an uploaded file. The blob is always stored
  (S3/MinIO); readable text formats also get their content inlined as `body`.
  Binary formats (PDF, DOCX, XLSX, PPTX…) are indexed asynchronously — the AI
  worker downloads the file, extracts the text, chunks and embeds it.
  """
  def create_from_upload(workspace_id, %Plug.Upload{} = upload, member \\ nil, opts \\ []) do
    body = inline_body(upload)

    file =
      case Mokaid.Files.create_from_upload(workspace_id, upload, member) do
        {:ok, file} -> file
        {:error, _} -> nil
      end

    will_index? = body != nil or (file != nil and extractable_filename?(upload.filename))

    create_item(
      workspace_id,
      %{
        "title" => upload.filename,
        "type" => "file",
        "agent_id" => opts[:agent_id],
        "project_id" => opts[:project_id],
        "category_id" => opts[:category_id],
        "file_id" => file && file.id,
        "body" => body,
        "status" => if(will_index?, do: "processing", else: "published"),
        "metadata" =>
          Map.merge(
            %{
              "original_filename" => upload.filename,
              "content_type" => upload.content_type
            },
            opts[:metadata] || %{}
          )
      },
      member
    )
  end

  # Inline the content of plain-text formats so they're readable immediately;
  # binary formats go through the worker's extractors instead.
  @inline_extensions ~w(txt md markdown csv tsv json html htm xml yaml yml)

  defp inline_body(%Plug.Upload{} = upload) do
    extension = upload.filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()

    with true <- extension in @inline_extensions,
         {:ok, content} <- File.read(upload.path),
         true <- String.valid?(content) do
      content
    else
      _ -> nil
    end
  end

  def delete_item(%KnowledgeItem{} = item) do
    Repo.delete(item)
  end

  def update_item(%KnowledgeItem{} = item, attrs) do
    old_body = item.body

    result =
      item
      |> KnowledgeItem.changeset(Map.put(attrs, "workspace_id", item.workspace_id))
      |> Repo.update()

    with {:ok, updated} <- result do
      if updated.body != old_body, do: maybe_enqueue_ingestion(updated)
      {:ok, updated}
    end
  end

  # File formats the AI worker can extract text from (see the worker's
  # app/memory/extractors.py — keep both lists in sync). Anything else with
  # no inline body is stored but not indexed.
  @extractable_extensions ~w(pdf docx xlsx xlsm xls pptx rtf txt md markdown csv tsv json html htm xml yaml yml)

  def extractable_extensions, do: @extractable_extensions

  @doc "True when a filename has a format the AI worker can extract text from."
  def extractable_filename?(filename) when is_binary(filename) do
    extension = filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    extension in @extractable_extensions
  end

  def extractable_filename?(_), do: false

  defp maybe_enqueue_ingestion(%KnowledgeItem{} = item) do
    cond do
      item.body not in [nil, ""] -> enqueue_ingestion(item)
      ingestable_file?(item) -> enqueue_ingestion(item)
      true -> :ok
    end
  end

  # Inline Oban testing (and misconfigured AI worker URLs) must not fail inserts.
  defp safe_enqueue_ingestion(item) do
    try do
      maybe_enqueue_ingestion(item)
    rescue
      e ->
        require Logger

        Logger.warning(
          "knowledge ingestion enqueue failed for item=#{item.id}: #{Exception.message(e)}"
        )

        :error
    end
  end

  # A linked file we can extract text from (binary formats: pdf, docx, xlsx…).
  defp ingestable_file?(%KnowledgeItem{} = item) do
    filename = item.metadata["original_filename"] || item.title

    (item.file_id != nil or item.drive_item_id != nil) and extractable_filename?(filename)
  end

  defp enqueue_ingestion(%KnowledgeItem{} = item) do
    config = Application.fetch_env!(:mokaid, :ai_worker)

    # :none is used in tests / offline — skip enqueue so items are not left
    # stuck in `indexing` with no worker to complete them.
    if config[:dispatch] == :none do
      :ok
    else
      item
      |> Ecto.Changeset.change(indexing_status: "indexing")
      |> Repo.update()

      %{knowledge_item_id: item.id, workspace_id: item.workspace_id}
      |> Mokaid.Knowledge.Workers.IngestionWorker.new()
      |> Oban.insert()

      :ok
    end
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

  def mark_failed(%KnowledgeItem{} = item, error \\ nil) do
    metadata =
      if is_binary(error) and error != "",
        do: Map.put(item.metadata || %{}, "indexing_error", String.slice(error, 0, 500)),
        else: item.metadata

    result =
      item
      |> Ecto.Changeset.change(indexing_status: "failed", status: "failed", metadata: metadata)
      |> Repo.update()

    with {:ok, updated} <- result do
      Realtime.broadcast_workspace(item.workspace_id, "knowledge.indexed", %{
        item_id: item.id,
        failed: true
      })

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

  @doc "Replaces all chunks of an item (used on re-ingestion)."
  def replace_chunks(%KnowledgeItem{} = item, chunks) do
    Repo.delete_all(from c in KnowledgeChunk, where: c.knowledge_item_id == ^item.id)
    insert_chunks(item, chunks)
  end

  # Reciprocal Rank Fusion constant (standard value from the literature) and
  # per-branch candidate pool for hybrid retrieval.
  @rrf_k 60
  @candidate_pool 20

  @doc """
  Hybrid search over knowledge chunks: semantic nearest-neighbor (cosine,
  pgvector HNSW) fused with lexical full-text search (Postgres tsvector) via
  Reciprocal Rank Fusion. Lexical matching catches exact terms (names, SKUs,
  legal references…) that embeddings blur, while the vector half handles
  paraphrase. When no `:query` text is provided this degrades gracefully to
  pure semantic search.

  Retrieval spans three knowledge levels: general workspace knowledge
  (no project, no agent), plus — when `opts` provide them — the knowledge
  scoped to the current project and to the current agent. Knowledge from
  other projects/agents is never leaked into a run.
  """
  def search_chunks(workspace_id, embedding, limit \\ 5, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    agent_id = Keyword.get(opts, :agent_id)
    query_text = presence(Keyword.get(opts, :query))

    pool = max(@candidate_pool, limit)

    semantic = semantic_search(workspace_id, embedding, pool, project_id, agent_id)
    lexical = lexical_search(workspace_id, query_text, pool, project_id, agent_id)

    graph_boost_ids =
      if query_text && Mokaid.Knowledge.Graph.enabled?(workspace_id) do
        MapSet.new(
          Mokaid.Knowledge.Graph.chunk_ids_for_query(workspace_id, query_text,
            project_id: project_id,
            agent_id: agent_id
          )
        )
      else
        MapSet.new()
      end

    fuse_results(semantic, lexical, limit, graph_boost_ids)
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_), do: nil

  defp semantic_search(workspace_id, embedding, pool, project_id, agent_id) do
    vector = Pgvector.new(embedding)

    from(c in KnowledgeChunk,
      join: i in assoc(c, :knowledge_item),
      where: c.workspace_id == ^workspace_id and not is_nil(c.embedding),
      where: i.status == "published",
      order_by: cosine_distance(c.embedding, ^vector),
      limit: ^pool,
      select: %{
        chunk: c,
        item_title: i.title,
        scope:
          fragment(
            "CASE WHEN ? IS NOT NULL THEN 'agent' WHEN ? IS NOT NULL THEN 'project' ELSE 'general' END",
            i.agent_id,
            i.project_id
          ),
        distance: cosine_distance(c.embedding, ^vector)
      }
    )
    |> scope_filter(project_id, agent_id)
    |> Repo.all()
  end

  defp lexical_search(_workspace_id, nil, _pool, _project_id, _agent_id), do: []

  defp lexical_search(workspace_id, query_text, pool, project_id, agent_id) do
    from(c in KnowledgeChunk,
      join: i in assoc(c, :knowledge_item),
      where: c.workspace_id == ^workspace_id,
      where: i.status == "published",
      where:
        fragment(
          "to_tsvector('simple', ?) @@ websearch_to_tsquery('simple', ?)",
          c.content,
          ^query_text
        ),
      order_by: [
        desc:
          fragment(
            "ts_rank(to_tsvector('simple', ?), websearch_to_tsquery('simple', ?))",
            c.content,
            ^query_text
          )
      ],
      limit: ^pool,
      select: %{
        chunk: c,
        item_title: i.title,
        scope:
          fragment(
            "CASE WHEN ? IS NOT NULL THEN 'agent' WHEN ? IS NOT NULL THEN 'project' ELSE 'general' END",
            i.agent_id,
            i.project_id
          ),
        distance: nil
      }
    )
    |> scope_filter(project_id, agent_id)
    |> Repo.all()
  end

  # Reciprocal Rank Fusion: each branch contributes 1/(k + rank) per chunk;
  # chunks found by both branches accumulate both contributions and float up.
  # Graph-anchored chunks get an extra boost so multi-hop structure surfaces.
  @graph_boost 0.015

  defp fuse_results(semantic, lexical, limit, graph_boost_ids) do
    scored =
      [semantic, lexical]
      |> Enum.reduce(%{}, fn results, acc ->
        results
        |> Enum.with_index(1)
        |> Enum.reduce(acc, fn {result, rank}, inner ->
          contribution = 1.0 / (@rrf_k + rank)

          Map.update(
            inner,
            result.chunk.id,
            Map.put(result, :score, contribution),
            fn existing ->
              existing
              |> Map.update!(:score, &(&1 + contribution))
              |> Map.update(:distance, result.distance, &(&1 || result.distance))
            end
          )
        end)
      end)

    scored
    |> Map.values()
    |> Enum.map(fn result ->
      if MapSet.member?(graph_boost_ids, result.chunk.id) do
        Map.update!(result, :score, &(&1 + @graph_boost))
      else
        result
      end
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
  end

  defp scope_filter(query, nil, nil) do
    where(query, [c, i], is_nil(i.project_id) and is_nil(i.agent_id))
  end

  defp scope_filter(query, project_id, nil) do
    where(
      query,
      [c, i],
      (is_nil(i.project_id) and is_nil(i.agent_id)) or i.project_id == ^project_id
    )
  end

  defp scope_filter(query, nil, agent_id) do
    where(
      query,
      [c, i],
      (is_nil(i.project_id) and is_nil(i.agent_id)) or i.agent_id == ^agent_id
    )
  end

  defp scope_filter(query, project_id, agent_id) do
    where(
      query,
      [c, i],
      (is_nil(i.project_id) and is_nil(i.agent_id)) or i.project_id == ^project_id or
        i.agent_id == ^agent_id
    )
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
