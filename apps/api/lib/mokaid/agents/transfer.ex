defmodule Mokaid.Agents.Transfer do
  @moduledoc """
  Paid cross-workspace agent copy.

  Clones an AI agent — profile, skills, level and all of its agent-scoped
  knowledge (items, chunks with embeddings, graph nodes/edges) — into another
  workspace the actor belongs to. The original agent is left untouched.

  Pricing: one agent's price (the specialist boost, `Archetypes.specialist_credits/0`),
  strictly debited from the TARGET workspace. Insufficient balance aborts the
  whole operation.

  The agent row is created synchronously (so the clone appears immediately);
  the knowledge corpus is copied by `AgentKnowledgeCopyWorker` in the
  background. Not copied on purpose: MCP grants (installations belong to the
  source workspace), chat conversations, task history, and file/drive
  references (chunk contents already carry everything RAG needs).
  """

  import Ecto.Query

  alias Mokaid.Agents
  alias Mokaid.Agents.{Agent, Archetypes}
  alias Mokaid.Agents.Workers.AgentKnowledgeCopyWorker
  alias Mokaid.Audit
  alias Mokaid.Billing
  alias Mokaid.Billing.Credits

  alias Mokaid.Knowledge.{
    KnowledgeCategory,
    KnowledgeChunk,
    KnowledgeEdge,
    KnowledgeItem,
    KnowledgeNode,
    KnowledgeNodeChunk
  }

  alias Mokaid.Members
  alias Mokaid.Permissions
  alias Mokaid.Realtime
  alias Mokaid.Repo

  @doc "Credits charged to the target workspace for a transfer."
  def transfer_credits, do: Archetypes.specialist_credits()

  @doc """
  Copies `agent_id` from the source workspace into the target workspace.

  The actor must be an active member of both workspaces, with `agents.view`
  on the source and `agents.create` on the target. Only AI agents that are
  not archived or mid-training can be copied.
  """
  def copy_agent(source_workspace_id, agent_id, target_workspace_id, actor_user) do
    with :ok <- ensure_distinct(source_workspace_id, target_workspace_id),
         {:ok, agent} <- fetch_source_agent(source_workspace_id, agent_id),
         :ok <- ensure_transferable(agent),
         {:ok, source_member} <- fetch_member(source_workspace_id, actor_user, :source),
         :ok <- Permissions.authorize(source_member, "agents.view"),
         {:ok, target_member} <- fetch_member(target_workspace_id, actor_user, :target),
         :ok <- Permissions.authorize(target_member, "agents.create"),
         {:ok, clone} <- insert_clone(agent, target_workspace_id, target_member) do
      after_commit(agent, clone, source_member, target_member)
      {:ok, clone}
    end
  end

  defp ensure_distinct(ws, ws), do: {:error, :same_workspace}
  defp ensure_distinct(_source, _target), do: :ok

  defp fetch_source_agent(workspace_id, agent_id) do
    case Agents.get_agent(workspace_id, agent_id) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  defp ensure_transferable(%Agent{} = agent) do
    cond do
      agent.kind != "ai" -> {:error, :only_ai_agents_transferable}
      not is_nil(agent.archived_at) -> {:error, :not_found}
      agent.status == "training" -> {:error, :agent_in_training}
      true -> :ok
    end
  end

  defp fetch_member(workspace_id, %{id: user_id}, side) do
    case Members.get_member_for_user(workspace_id, user_id) do
      nil ->
        {:error,
         if(side == :target, do: :not_a_member_of_target_workspace, else: :forbidden)}

      member ->
        {:ok, member}
    end
  end

  defp insert_clone(%Agent{} = agent, target_workspace_id, target_member) do
    credits = transfer_credits()

    result =
      Repo.transaction(fn ->
        # Same advisory lock as agent creation so quota + seat stay consistent.
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [
          to_string(target_workspace_id)
        ])

        if Agents.active_agent_count(target_workspace_id) >=
             Billing.agent_limit(target_workspace_id) do
          Repo.rollback(:agent_limit_reached)
        end

        seat =
          case Agents.next_free_seat(target_workspace_id) do
            {:ok, seat} -> seat
            {:error, :office_full} -> Repo.rollback(:office_full)
          end

        clone =
          case %Agent{}
               |> Agent.internal_changeset(clone_attrs(agent, target_workspace_id, target_member, seat))
               |> Repo.insert() do
            {:ok, clone} -> clone
            {:error, changeset} -> Repo.rollback(changeset)
          end

        case Credits.charge_strict(target_workspace_id, credits,
               kind: "agent_transfer",
               agent_id: clone.id,
               description: "Agent transfer: #{agent.display_name}"
             ) do
          {:ok, _sub, _credits} -> clone
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, clone} -> {:ok, clone}
      {:error, reason} -> {:error, reason}
    end
  end

  defp clone_attrs(%Agent{} = agent, target_workspace_id, target_member, seat) do
    %{
      "workspace_id" => target_workspace_id,
      "kind" => "ai",
      "display_name" => agent.display_name,
      "avatar_config" => agent.avatar_config || %{},
      "avatar_asset_id" => agent.avatar_asset_id,
      "role_title" => agent.role_title,
      "department" => agent.department,
      "status" => "idle",
      "presence_status" => "online",
      "control_mode" => "ai_controlled",
      "ai_enabled" => true,
      "human_takeover_enabled" => agent.human_takeover_enabled,
      "skills" => agent.skills || [],
      "capabilities" => clone_capabilities(agent),
      "level" => agent.level,
      "xp" => agent.xp,
      "xp_for_next_level" => agent.xp_for_next_level,
      "missions_completed" => agent.missions_completed,
      "performance_score" => agent.performance_score,
      "created_by_member_id" => target_member.id,
      "seat_index" => seat
    }
  end

  # Drop the training state (the clone is ready, not mid-boost) and record
  # provenance so the UI and audits can tell copies apart from originals.
  defp clone_capabilities(%Agent{} = agent) do
    (agent.capabilities || %{})
    |> Map.delete("training")
    |> Map.put("transferred_from", %{
      "workspace_id" => agent.workspace_id,
      "agent_id" => agent.id,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp after_commit(agent, clone, source_member, target_member) do
    Credits.broadcast_balance(clone.workspace_id)

    Audit.log(agent.workspace_id, source_member, "agent.transfer_out", "agent", agent.id, %{
      target_workspace_id: clone.workspace_id,
      clone_agent_id: clone.id
    })

    Audit.log(clone.workspace_id, target_member, "agent.transfer_in", "agent", clone.id, %{
      source_workspace_id: agent.workspace_id,
      source_agent_id: agent.id
    })

    Realtime.broadcast_workspace(clone.workspace_id, "agent.created", %{agent_id: clone.id})

    %{
      "source_workspace_id" => agent.workspace_id,
      "source_agent_id" => agent.id,
      "target_workspace_id" => clone.workspace_id,
      "target_agent_id" => clone.id
    }
    |> AgentKnowledgeCopyWorker.new()
    |> Oban.insert()
  end

  ## ---------- Knowledge copy (runs in the background worker) ----------

  @doc """
  Copies every agent-scoped knowledge item of the source agent into the
  target workspace: item, chunks (content + embedding, no re-indexing) and
  the item's graph nodes/edges/chunk links. Idempotent — items already copied
  (tracked via `metadata.transferred_from_item_id`) are skipped, so worker
  retries are safe.
  """
  def copy_knowledge(source_workspace_id, source_agent_id, target_workspace_id, target_agent_id) do
    items =
      Repo.all(
        from i in KnowledgeItem,
          where: i.workspace_id == ^source_workspace_id and i.agent_id == ^source_agent_id
      )

    Enum.each(items, &copy_item(&1, target_workspace_id, target_agent_id))

    Realtime.broadcast_workspace(target_workspace_id, "agent.updated", %{
      agent_id: target_agent_id
    })

    :ok
  end

  defp copy_item(%KnowledgeItem{} = item, target_workspace_id, target_agent_id) do
    already_copied? =
      Repo.exists?(
        from i in KnowledgeItem,
          where:
            i.workspace_id == ^target_workspace_id and i.agent_id == ^target_agent_id and
              fragment("?->>'transferred_from_item_id' = ?", i.metadata, ^item.id)
      )

    unless already_copied? do
      {:ok, _} =
        Repo.transaction(fn ->
          category_id = clone_category(item.category_id, target_workspace_id)

          new_item = insert_item_copy(item, target_workspace_id, target_agent_id, category_id)
          chunk_map = copy_chunks(item.id, new_item)
          node_map = copy_nodes(item.id, new_item)
          copy_edges(item.id, new_item, node_map)
          copy_node_chunks(item.id, new_item, node_map, chunk_map)

          new_item
        end)
    end

    :ok
  end

  defp clone_category(nil, _target_workspace_id), do: nil

  defp clone_category(category_id, target_workspace_id) do
    case Repo.get(KnowledgeCategory, category_id) do
      nil ->
        nil

      source ->
        existing =
          Repo.one(
            from c in KnowledgeCategory,
              where: c.workspace_id == ^target_workspace_id and c.name == ^source.name
          )

        case existing do
          %KnowledgeCategory{id: id} ->
            id

          nil ->
            {:ok, _} =
              %KnowledgeCategory{}
              |> KnowledgeCategory.changeset(%{
                "workspace_id" => target_workspace_id,
                "name" => source.name,
                "color" => source.color,
                "position" => source.position
              })
              |> Repo.insert(
                on_conflict: :nothing,
                conflict_target: [:workspace_id, :name]
              )

            # Re-read: with client-generated binary ids, on_conflict: :nothing
            # still returns a struct whose id may not exist in the database.
            Repo.one(
              from c in KnowledgeCategory,
                where: c.workspace_id == ^target_workspace_id and c.name == ^source.name,
                select: c.id
            )
        end
    end
  end

  defp insert_item_copy(%KnowledgeItem{} = item, target_workspace_id, target_agent_id, category_id) do
    metadata = Map.put(item.metadata || %{}, "transferred_from_item_id", item.id)

    %KnowledgeItem{}
    |> KnowledgeItem.changeset(%{
      "workspace_id" => target_workspace_id,
      "agent_id" => target_agent_id,
      "category_id" => category_id,
      "title" => item.title,
      "type" => item.type,
      "source_url" => item.source_url,
      "body" => item.body,
      "status" => item.status,
      "visibility" => item.visibility,
      "tags" => item.tags || [],
      "version" => item.version,
      "indexing_status" => item.indexing_status,
      "metadata" => metadata,
      "last_reviewed_at" => item.last_reviewed_at
    })
    |> Repo.insert!()
  end

  defp copy_chunks(source_item_id, %KnowledgeItem{} = new_item) do
    from(c in KnowledgeChunk, where: c.knowledge_item_id == ^source_item_id)
    |> Repo.all()
    |> Map.new(fn chunk ->
      copy =
        %KnowledgeChunk{}
        |> KnowledgeChunk.changeset(%{
          "workspace_id" => new_item.workspace_id,
          "knowledge_item_id" => new_item.id,
          "chunk_index" => chunk.chunk_index,
          "content" => chunk.content,
          "embedding" => chunk.embedding,
          "metadata" => chunk.metadata || %{}
        })
        |> Repo.insert!()

      {chunk.id, copy.id}
    end)
  end

  defp copy_nodes(source_item_id, %KnowledgeItem{} = new_item) do
    from(n in KnowledgeNode, where: n.knowledge_item_id == ^source_item_id)
    |> Repo.all()
    |> Map.new(fn node ->
      copy =
        %KnowledgeNode{}
        |> KnowledgeNode.changeset(%{
          "workspace_id" => new_item.workspace_id,
          "knowledge_item_id" => new_item.id,
          "agent_id" => new_item.agent_id,
          "key" => node.key,
          "label" => node.label,
          "kind" => node.kind,
          "degree" => node.degree,
          "lesson_status" => node.lesson_status,
          "metadata" => node.metadata || %{}
        })
        |> Repo.insert!()

      {node.id, copy.id}
    end)
  end

  defp copy_edges(source_item_id, %KnowledgeItem{} = new_item, node_map) do
    from(e in KnowledgeEdge, where: e.knowledge_item_id == ^source_item_id)
    |> Repo.all()
    |> Enum.each(fn edge ->
      source_node_id = Map.get(node_map, edge.source_node_id)
      target_node_id = Map.get(node_map, edge.target_node_id)

      # Edges pointing at nodes of other items are rebuilt when the target
      # workspace's graph is next reindexed; only intra-item edges are copied.
      if source_node_id && target_node_id do
        %KnowledgeEdge{}
        |> KnowledgeEdge.changeset(%{
          "workspace_id" => new_item.workspace_id,
          "knowledge_item_id" => new_item.id,
          "source_node_id" => source_node_id,
          "target_node_id" => target_node_id,
          "relation" => edge.relation,
          "confidence" => edge.confidence,
          "weight" => edge.weight,
          "metadata" => edge.metadata || %{}
        })
        |> Repo.insert!(on_conflict: :nothing)
      end
    end)
  end

  defp copy_node_chunks(source_item_id, %KnowledgeItem{} = new_item, node_map, chunk_map) do
    from(nc in KnowledgeNodeChunk,
      join: n in KnowledgeNode,
      on: n.id == nc.node_id,
      where: n.knowledge_item_id == ^source_item_id,
      select: nc
    )
    |> Repo.all()
    |> Enum.each(fn link ->
      node_id = Map.get(node_map, link.node_id)
      chunk_id = Map.get(chunk_map, link.chunk_id)

      if node_id && chunk_id do
        %KnowledgeNodeChunk{}
        |> KnowledgeNodeChunk.changeset(%{
          "workspace_id" => new_item.workspace_id,
          "node_id" => node_id,
          "chunk_id" => chunk_id,
          "relevance" => link.relevance
        })
        |> Repo.insert!(on_conflict: :nothing)
      end
    end)
  end
end
