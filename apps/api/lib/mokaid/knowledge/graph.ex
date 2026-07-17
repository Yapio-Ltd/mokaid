defmodule Mokaid.Knowledge.Graph do
  @moduledoc """
  Workspace knowledge graph: concepts/entities as nodes, typed edges with
  confidence tags (EXTRACTED | INFERRED | AMBIGUOUS), Leiden-style communities,
  path/explain/traverse queries, and agent learning outcomes (reflect).

  Complements hybrid chunk RAG — never replaces it. GraphRAG boosts chunks that
  are anchored to nodes in a query subgraph.
  """

  import Ecto.Query

  alias Mokaid.Knowledge.{
    KnowledgeChunk,
    KnowledgeCommunity,
    KnowledgeEdge,
    KnowledgeGraphOutcome,
    KnowledgeItem,
    KnowledgeNode,
    KnowledgeNodeChunk
  }

  alias Mokaid.Repo

  @office_zones ~w(finance legal product engineering design marketing ops lobby)

  # ─── Feature gate ──────────────────────────────────────────────────────────

  @doc """
  Whether the workspace plan includes the knowledge graph.

  Free → false; Starter → project-scoped only; Professional → full workspace.
  """
  def enabled?(workspace_id) do
    case Mokaid.Billing.get_subscription(workspace_id) do
      %{plan: %{key: key}} when key in ["starter", "professional"] -> true
      _ -> false
    end
  end

  @doc "Starter is project-scoped; Professional gets workspace-wide graph tools."
  def scope_level(workspace_id) do
    case Mokaid.Billing.get_subscription(workspace_id) do
      %{plan: %{key: "professional"}} -> :workspace
      %{plan: %{key: "starter"}} -> :project
      _ -> :none
    end
  end

  # Cost of a full graph re-index pass (credit debit).
  @reindex_credits 25

  def reindex_credits, do: @reindex_credits

  # ─── Replace graph for an item (called after chunk ingestion) ──────────────

  @doc """
  Replaces all graph nodes/edges for a knowledge item with a fresh extraction.
  `payload` shape (from the AI worker):

      %{
        "nodes" => [%{"key" => "...", "label" => "...", "kind" => "concept", ...}],
        "edges" => [%{"source" => key, "target" => key, "relation" => "...",
                      "confidence" => "EXTRACTED"|"INFERRED"|"AMBIGUOUS"}],
        "chunk_links" => [%{"node_key" => "...", "chunk_index" => 0}]  # optional
      }
  """
  def replace_item_graph(%KnowledgeItem{} = item, payload) when is_map(payload) do
    nodes_in = List.wrap(payload["nodes"] || payload[:nodes])
    edges_in = List.wrap(payload["edges"] || payload[:edges])
    links_in = List.wrap(payload["chunk_links"] || payload[:chunk_links])

    Repo.transaction(fn ->
      clear_item_graph(item)

      key_to_id =
        Enum.reduce(nodes_in, %{}, fn node, acc ->
          key = node_key(node)
          label = node_label(node, key)
          kind = node["kind"] || node[:kind] || "concept"

          {:ok, row} =
            %KnowledgeNode{}
            |> KnowledgeNode.changeset(%{
              workspace_id: item.workspace_id,
              knowledge_item_id: item.id,
              project_id: item.project_id,
              agent_id: item.agent_id,
              key: key,
              label: label,
              kind: normalize_kind(kind),
              metadata: Map.drop(node, ["key", "label", "kind", :key, :label, :kind])
            })
            |> Repo.insert()

          Map.put(acc, key, row.id)
        end)

      Enum.each(edges_in, fn edge ->
        source_key = edge["source"] || edge[:source]
        target_key = edge["target"] || edge[:target]
        source_id = key_to_id[source_key]
        target_id = key_to_id[target_key]

        if source_id && target_id && source_id != target_id do
          %KnowledgeEdge{}
          |> KnowledgeEdge.changeset(%{
            workspace_id: item.workspace_id,
            knowledge_item_id: item.id,
            source_node_id: source_id,
            target_node_id: target_id,
            relation: edge["relation"] || edge[:relation] || "related_to",
            confidence: normalize_confidence(edge["confidence"] || edge[:confidence]),
            weight: edge["weight"] || edge[:weight] || 1.0,
            metadata: %{}
          })
          |> Repo.insert(on_conflict: :nothing)
        end
      end)

      refresh_degrees(Map.values(key_to_id))
      link_chunks(item, key_to_id, links_in)
      map_size(key_to_id)
    end)
  end

  def replace_item_graph(_item, _), do: {:ok, 0}

  defp clear_item_graph(%KnowledgeItem{} = item) do
    node_ids =
      from(n in KnowledgeNode, where: n.knowledge_item_id == ^item.id, select: n.id)
      |> Repo.all()

    if node_ids != [] do
      from(l in KnowledgeNodeChunk, where: l.node_id in ^node_ids) |> Repo.delete_all()
      from(e in KnowledgeEdge, where: e.knowledge_item_id == ^item.id) |> Repo.delete_all()
    end

    from(n in KnowledgeNode, where: n.knowledge_item_id == ^item.id) |> Repo.delete_all()
  end

  defp link_chunks(%KnowledgeItem{} = item, key_to_id, links_in) do
    chunks =
      from(c in KnowledgeChunk,
        where: c.knowledge_item_id == ^item.id,
        select: {c.chunk_index, c.id}
      )
      |> Repo.all()
      |> Map.new()

    Enum.each(links_in, fn link ->
      node_key = link["node_key"] || link[:node_key]
      chunk_index = link["chunk_index"] || link[:chunk_index]
      node_id = key_to_id[node_key]
      chunk_id = chunks[chunk_index]

      if node_id && chunk_id do
        %KnowledgeNodeChunk{}
        |> KnowledgeNodeChunk.changeset(%{
          workspace_id: item.workspace_id,
          node_id: node_id,
          chunk_id: chunk_id,
          relevance: link["relevance"] || link[:relevance] || 1.0
        })
        |> Repo.insert(on_conflict: :nothing)
      end
    end)
  end

  defp refresh_degrees(node_ids) when is_list(node_ids) do
    Enum.each(node_ids, fn id ->
      degree =
        from(e in KnowledgeEdge,
          where: e.source_node_id == ^id or e.target_node_id == ^id,
          select: count(e.id)
        )
        |> Repo.one()

      from(n in KnowledgeNode, where: n.id == ^id)
      |> Repo.update_all(set: [degree: degree || 0])
    end)
  end

  # ─── Queries: traverse / path / explain ────────────────────────────────────

  @doc "Subgraph around nodes matching a free-text query (label/key ILIKE)."
  def traverse(workspace_id, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 40)
    depth = Keyword.get(opts, :depth, 2)
    project_id = Keyword.get(opts, :project_id)
    agent_id = Keyword.get(opts, :agent_id)

    seeds =
      from(n in KnowledgeNode,
        where: n.workspace_id == ^workspace_id,
        where: ilike(n.label, ^"%#{query}%") or ilike(n.key, ^"%#{query}%"),
        limit: 12
      )
      |> scope_nodes(project_id, agent_id)
      |> Repo.all()

    expand_subgraph(workspace_id, seeds, depth, limit, project_id, agent_id)
  end

  @doc "Shortest path (BFS) between two concept labels/keys."
  def shortest_path(workspace_id, from_query, to_query, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    agent_id = Keyword.get(opts, :agent_id)

    from_node = find_best_node(workspace_id, from_query, project_id, agent_id)
    to_node = find_best_node(workspace_id, to_query, project_id, agent_id)

    cond do
      is_nil(from_node) or is_nil(to_node) ->
        %{
          path: [],
          hops: 0,
          from: from_node && node_json(from_node),
          to: to_node && node_json(to_node)
        }

      from_node.id == to_node.id ->
        %{
          path: [node_json(from_node)],
          hops: 0,
          from: node_json(from_node),
          to: node_json(to_node)
        }

      true ->
        case bfs_path(workspace_id, from_node.id, to_node.id) do
          nil ->
            %{path: [], hops: 0, from: node_json(from_node), to: node_json(to_node)}

          ids ->
            nodes =
              from(n in KnowledgeNode, where: n.id in ^ids)
              |> Repo.all()
              |> Map.new(&{&1.id, &1})

            path = Enum.map(ids, &node_json(Map.get(nodes, &1)))

            %{
              path: path,
              hops: max(length(ids) - 1, 0),
              from: node_json(from_node),
              to: node_json(to_node)
            }
        end
    end
  end

  @doc "Neighborhood of a concept with edge confidence tags."
  def explain(workspace_id, query, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    agent_id = Keyword.get(opts, :agent_id)
    node = find_best_node(workspace_id, query, project_id, agent_id)

    if is_nil(node) do
      %{node: nil, connections: [], lesson: nil}
    else
      edges =
        from(e in KnowledgeEdge,
          where: e.workspace_id == ^workspace_id,
          where: e.source_node_id == ^node.id or e.target_node_id == ^node.id,
          preload: [:source_node, :target_node],
          limit: 50
        )
        |> Repo.all()

      connections =
        Enum.map(edges, fn e ->
          other = if e.source_node_id == node.id, do: e.target_node, else: e.source_node
          direction = if e.source_node_id == node.id, do: "out", else: "in"

          %{
            direction: direction,
            relation: e.relation,
            confidence: e.confidence,
            node: node_json(other)
          }
        end)

      %{
        node: node_json(node),
        connections: connections,
        lesson: node.lesson_status,
        community_id: node.community_id
      }
    end
  end

  # ─── GraphRAG: chunk ids reachable from a query subgraph ───────────────────

  @doc "Chunk IDs linked to nodes in a traverse subgraph (for RRF boost)."
  def chunk_ids_for_query(workspace_id, query, opts \\ [])

  def chunk_ids_for_query(workspace_id, query, opts) when is_binary(query) and query != "" do
    subgraph = traverse(workspace_id, query, Keyword.put(opts, :limit, 30))
    node_ids = Enum.map(subgraph.nodes, & &1.id)

    if node_ids == [] do
      []
    else
      from(l in KnowledgeNodeChunk,
        where: l.workspace_id == ^workspace_id and l.node_id in ^node_ids,
        select: l.chunk_id,
        distinct: true
      )
      |> Repo.all()
    end
  end

  def chunk_ids_for_query(_, _, _), do: []

  # ─── Communities (simple connected-component / degree clustering) ──────────

  @doc """
  Rebuilds communities for a workspace using a lightweight connected-component
  partition + god-node scoring. Assigns office zones round-robin for 3D mapping.
  """
  def rebuild_communities(workspace_id, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    agent_id = Keyword.get(opts, :agent_id)

    nodes =
      from(n in KnowledgeNode, where: n.workspace_id == ^workspace_id)
      |> scope_nodes(project_id, agent_id)
      |> Repo.all()

    if nodes == [] do
      {:ok, 0}
    else
      edges =
        from(e in KnowledgeEdge,
          where: e.workspace_id == ^workspace_id,
          select: {e.source_node_id, e.target_node_id}
        )
        |> Repo.all()

      components = connected_components(Enum.map(nodes, & &1.id), edges)
      node_map = Map.new(nodes, &{&1.id, &1})

      Repo.transaction(fn ->
        # Clear prior communities in this scope.
        old =
          from(c in KnowledgeCommunity, where: c.workspace_id == ^workspace_id)
          |> maybe_community_scope(project_id, agent_id)
          |> Repo.all()

        Enum.each(old, fn c ->
          from(n in KnowledgeNode, where: n.community_id == ^c.id)
          |> Repo.update_all(set: [community_id: nil])

          Repo.delete(c)
        end)

        components
        |> Enum.with_index(1)
        |> Enum.reduce(0, fn {member_ids, index}, count ->
          members = Enum.map(member_ids, &node_map[&1]) |> Enum.reject(&is_nil/1)
          god = Enum.max_by(members, & &1.degree, fn -> List.first(members) end)
          label = (god && god.label) || "Community #{index}"
          slug = slugify("#{label}-#{index}")
          zone = Enum.at(@office_zones, rem(index - 1, length(@office_zones)))

          {:ok, community} =
            %KnowledgeCommunity{}
            |> KnowledgeCommunity.changeset(%{
              workspace_id: workspace_id,
              project_id: project_id,
              agent_id: agent_id,
              label: label,
              slug: slug,
              node_count: length(members),
              god_score: (god && god.degree * 1.0) || 0.0,
              office_zone: zone,
              metadata: %{"god_node_id" => god && god.id}
            })
            |> Repo.insert()

          from(n in KnowledgeNode, where: n.id in ^member_ids)
          |> Repo.update_all(set: [community_id: community.id])

          count + 1
        end)
      end)
    end
  end

  defp maybe_community_scope(query, nil, nil),
    do: where(query, [c], is_nil(c.project_id) and is_nil(c.agent_id))

  defp maybe_community_scope(query, project_id, nil) when not is_nil(project_id),
    do:
      where(
        query,
        [c],
        c.project_id == ^project_id or (is_nil(c.project_id) and is_nil(c.agent_id))
      )

  defp maybe_community_scope(query, nil, agent_id) when not is_nil(agent_id),
    do:
      where(query, [c], c.agent_id == ^agent_id or (is_nil(c.project_id) and is_nil(c.agent_id)))

  defp maybe_community_scope(query, project_id, agent_id),
    do:
      where(
        query,
        [c],
        c.project_id == ^project_id or c.agent_id == ^agent_id or
          (is_nil(c.project_id) and is_nil(c.agent_id))
      )

  # ─── Outcomes / reflect (agent memory) ─────────────────────────────────────

  def save_outcome(workspace_id, attrs) do
    %KnowledgeGraphOutcome{}
    |> KnowledgeGraphOutcome.changeset(Map.put(attrs, "workspace_id", workspace_id))
    |> Repo.insert()
    |> tap(fn
      {:ok, outcome} -> apply_lesson_tags(outcome)
      _ -> :ok
    end)
  end

  defp apply_lesson_tags(%KnowledgeGraphOutcome{node_ids: ids, outcome: outcome})
       when is_list(ids) and ids != [] do
    status =
      case outcome do
        "useful" -> "preferred"
        "dead_end" -> "contested"
        "corrected" -> "tentative"
        _ -> nil
      end

    if status do
      from(n in KnowledgeNode, where: n.id in ^ids)
      |> Repo.update_all(set: [lesson_status: status])
    end
  end

  defp apply_lesson_tags(_), do: :ok

  @doc "Aggregate recent outcomes into preferred/contested hints for an agent."
  def reflect(workspace_id, agent_id \\ nil) do
    base =
      from(o in KnowledgeGraphOutcome,
        where: o.workspace_id == ^workspace_id,
        order_by: [desc: o.inserted_at],
        limit: 100
      )

    query = if agent_id, do: where(base, [o], o.agent_id == ^agent_id), else: base
    outcomes = Repo.all(query)

    preferred = Enum.count(outcomes, &(&1.outcome == "useful"))
    contested = Enum.count(outcomes, &(&1.outcome == "dead_end"))
    corrected = Enum.count(outcomes, &(&1.outcome == "corrected"))

    %{
      total: length(outcomes),
      preferred: preferred,
      contested: contested,
      corrected: corrected,
      lessons:
        outcomes
        |> Enum.take(10)
        |> Enum.map(fn o ->
          %{
            outcome: o.outcome,
            question: o.question,
            answer_summary: o.answer_summary,
            node_ids: o.node_ids
          }
        end)
    }
  end

  # ─── Task routing via communities ──────────────────────────────────────────

  @doc """
  Scores agents by overlap between task concept tokens and community labels /
  node labels in each agent's graph scope. Returns [{agent_id, score, reasons}].
  """
  def rank_agents_for_task(workspace_id, task_text, agent_ids)
      when is_list(agent_ids) and agent_ids != [] do
    tokens =
      task_text
      |> to_string()
      |> String.downcase()
      |> String.split(~r/[^a-z0-9àâäéèêëïîôùûüç]+/u, trim: true)
      |> Enum.reject(&(String.length(&1) < 3))
      |> Enum.uniq()
      |> Enum.take(24)

    if tokens == [] do
      Enum.map(agent_ids, &{&1, 0, []})
    else
      Enum.map(agent_ids, fn agent_id ->
        score =
          from(n in KnowledgeNode,
            where: n.workspace_id == ^workspace_id,
            where: n.agent_id == ^agent_id or is_nil(n.agent_id),
            where:
              fragment(
                "EXISTS (SELECT 1 FROM unnest(?::text[]) t WHERE lower(?) LIKE '%' || t || '%' OR lower(?) LIKE '%' || t || '%')",
                ^tokens,
                n.label,
                n.key
              ),
            select: count(n.id)
          )
          |> Repo.one() || 0

        communities =
          from(c in KnowledgeCommunity,
            where: c.workspace_id == ^workspace_id,
            where: c.agent_id == ^agent_id or is_nil(c.agent_id),
            select: c.label,
            limit: 5
          )
          |> Repo.all()

        {agent_id, score, communities}
      end)
      |> Enum.sort_by(fn {_id, score, _} -> score end, :desc)
    end
  end

  def rank_agents_for_task(_, _, _), do: []

  # ─── Snapshot for UI / company-brain report ────────────────────────────────

  def snapshot(workspace_id, opts \\ []) do
    project_id = Keyword.get(opts, :project_id)
    agent_id = Keyword.get(opts, :agent_id)

    nodes =
      from(n in KnowledgeNode, where: n.workspace_id == ^workspace_id, order_by: [desc: n.degree])
      |> scope_nodes(project_id, agent_id)
      |> limit(200)
      |> Repo.all()

    node_ids = Enum.map(nodes, & &1.id)

    edges =
      if node_ids == [] do
        []
      else
        from(e in KnowledgeEdge,
          where: e.workspace_id == ^workspace_id,
          where: e.source_node_id in ^node_ids and e.target_node_id in ^node_ids,
          limit: 400
        )
        |> Repo.all()
      end

    communities =
      from(c in KnowledgeCommunity,
        where: c.workspace_id == ^workspace_id,
        order_by: [desc: c.god_score]
      )
      |> maybe_community_scope(project_id, agent_id)
      |> Repo.all()

    god_nodes = Enum.take(nodes, 8)

    %{
      enabled: enabled?(workspace_id),
      scope_level: scope_level(workspace_id),
      node_count: length(nodes),
      edge_count: length(edges),
      community_count: length(communities),
      god_nodes: Enum.map(god_nodes, &node_json/1),
      communities: Enum.map(communities, &community_json/1),
      nodes: Enum.map(nodes, &node_json/1),
      edges: Enum.map(edges, &edge_json/1),
      suggested_questions: suggested_questions(god_nodes, communities)
    }
  end

  defp suggested_questions(god_nodes, communities) do
    qs =
      Enum.flat_map(god_nodes, fn n ->
        ["What connects to #{n.label}?", "Explain #{n.label}"]
      end) ++
        Enum.flat_map(communities, fn c ->
          ["What is in the #{c.label} knowledge cluster?"]
        end)

    Enum.take(qs, 5)
  end

  # ─── Internals ─────────────────────────────────────────────────────────────

  defp expand_subgraph(workspace_id, seeds, depth, limit, project_id, agent_id) do
    seed_ids = Enum.map(seeds, & &1.id)
    visited = MapSet.new(seed_ids)
    frontier = seed_ids

    {all_ids, _} =
      Enum.reduce(1..max(depth, 0), {visited, frontier}, fn _, {seen, front} ->
        if front == [] or MapSet.size(seen) >= limit do
          {seen, []}
        else
          neighbor_ids =
            from(e in KnowledgeEdge,
              where: e.workspace_id == ^workspace_id,
              where: e.source_node_id in ^front or e.target_node_id in ^front,
              select: {e.source_node_id, e.target_node_id}
            )
            |> Repo.all()
            |> Enum.flat_map(fn {s, t} -> [s, t] end)
            |> Enum.reject(&MapSet.member?(seen, &1))
            |> Enum.uniq()
            |> Enum.take(limit - MapSet.size(seen))

          {MapSet.union(seen, MapSet.new(neighbor_ids)), neighbor_ids}
        end
      end)

    ids = all_ids |> MapSet.to_list() |> Enum.take(limit)

    nodes =
      if ids == [] do
        []
      else
        from(n in KnowledgeNode, where: n.id in ^ids)
        |> scope_nodes(project_id, agent_id)
        |> Repo.all()
      end

    edges =
      if ids == [] do
        []
      else
        from(e in KnowledgeEdge,
          where: e.workspace_id == ^workspace_id,
          where: e.source_node_id in ^ids and e.target_node_id in ^ids
        )
        |> Repo.all()
      end

    %{
      nodes: Enum.map(nodes, &node_json/1),
      edges: Enum.map(edges, &edge_json/1),
      seed_count: length(seeds)
    }
  end

  defp find_best_node(workspace_id, query, project_id, agent_id) do
    q = String.trim(query || "")

    if q == "" do
      nil
    else
      from(n in KnowledgeNode,
        where: n.workspace_id == ^workspace_id,
        where: ilike(n.label, ^"%#{q}%") or ilike(n.key, ^"%#{q}%") or n.key == ^slugify(q),
        order_by: [desc: n.degree],
        limit: 1
      )
      |> scope_nodes(project_id, agent_id)
      |> Repo.one()
    end
  end

  defp bfs_path(workspace_id, start_id, goal_id) do
    adjacency =
      from(e in KnowledgeEdge,
        where: e.workspace_id == ^workspace_id,
        select: {e.source_node_id, e.target_node_id}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {s, t}, acc ->
        acc
        |> Map.update(s, [t], &[t | &1])
        |> Map.update(t, [s], &[s | &1])
      end)

    bfs_loop(
      adjacency,
      :queue.from_list([{start_id, [start_id]}]),
      MapSet.new([start_id]),
      goal_id
    )
  end

  defp bfs_loop(adj, queue, seen, goal) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, {^goal, path}}, _rest} ->
        path

      {{:value, {current, path}}, rest} ->
        {queue2, seen2} =
          Enum.reduce(Map.get(adj, current, []), {rest, seen}, fn neighbor, {q, s} ->
            if MapSet.member?(s, neighbor) do
              {q, s}
            else
              {:queue.in({neighbor, path ++ [neighbor]}, q), MapSet.put(s, neighbor)}
            end
          end)

        bfs_loop(adj, queue2, seen2, goal)
    end
  end

  defp connected_components(node_ids, edges) do
    adj =
      Enum.reduce(edges, %{}, fn {s, t}, acc ->
        acc
        |> Map.update(s, [t], &[t | &1])
        |> Map.update(t, [s], &[s | &1])
      end)

    Enum.reduce(node_ids, {MapSet.new(), []}, fn id, {seen, comps} ->
      if MapSet.member?(seen, id) do
        {seen, comps}
      else
        component = dfs_collect(id, adj, MapSet.new())
        {MapSet.union(seen, component), [MapSet.to_list(component) | comps]}
      end
    end)
    |> elem(1)
    |> Enum.reject(&(&1 == []))
  end

  defp dfs_collect(id, adj, seen) do
    if MapSet.member?(seen, id) do
      seen
    else
      Enum.reduce(Map.get(adj, id, []), MapSet.put(seen, id), fn n, acc ->
        dfs_collect(n, adj, acc)
      end)
    end
  end

  defp scope_nodes(query, nil, nil),
    do: where(query, [n], is_nil(n.project_id) and is_nil(n.agent_id))

  defp scope_nodes(query, project_id, nil) when not is_nil(project_id),
    do:
      where(
        query,
        [n],
        (is_nil(n.project_id) and is_nil(n.agent_id)) or n.project_id == ^project_id
      )

  defp scope_nodes(query, nil, agent_id) when not is_nil(agent_id),
    do:
      where(
        query,
        [n],
        (is_nil(n.project_id) and is_nil(n.agent_id)) or n.agent_id == ^agent_id
      )

  defp scope_nodes(query, project_id, agent_id),
    do:
      where(
        query,
        [n],
        (is_nil(n.project_id) and is_nil(n.agent_id)) or n.project_id == ^project_id or
          n.agent_id == ^agent_id
      )

  defp node_key(node) do
    raw = node["key"] || node[:key] || node["label"] || node[:label] || "node"
    slugify(to_string(raw))
  end

  defp node_label(node, key) do
    (node["label"] || node[:label] || key) |> to_string() |> String.slice(0, 200)
  end

  defp normalize_kind(kind) when is_binary(kind) do
    k = String.downcase(kind)
    if k in ~w(concept entity person org product process document term), do: k, else: "concept"
  end

  defp normalize_kind(_), do: "concept"

  defp normalize_confidence(c) when c in ["EXTRACTED", "INFERRED", "AMBIGUOUS"], do: c

  defp normalize_confidence(c) when is_binary(c),
    do:
      String.upcase(c)
      |> then(fn
        x when x in ["EXTRACTED", "INFERRED", "AMBIGUOUS"] -> x
        _ -> "INFERRED"
      end)

  defp normalize_confidence(_), do: "INFERRED"

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 80)
    |> then(fn s -> if s == "", do: "node", else: s end)
  end

  def node_json(nil), do: nil

  def node_json(%KnowledgeNode{} = n) do
    %{
      id: n.id,
      key: n.key,
      label: n.label,
      kind: n.kind,
      degree: n.degree,
      lesson_status: n.lesson_status,
      community_id: n.community_id,
      knowledge_item_id: n.knowledge_item_id,
      project_id: n.project_id,
      agent_id: n.agent_id
    }
  end

  def edge_json(%KnowledgeEdge{} = e) do
    %{
      id: e.id,
      source: e.source_node_id,
      target: e.target_node_id,
      relation: e.relation,
      confidence: e.confidence,
      weight: e.weight
    }
  end

  def community_json(%KnowledgeCommunity{} = c) do
    %{
      id: c.id,
      label: c.label,
      slug: c.slug,
      node_count: c.node_count,
      god_score: c.god_score,
      office_zone: c.office_zone,
      project_id: c.project_id,
      agent_id: c.agent_id
    }
  end
end
