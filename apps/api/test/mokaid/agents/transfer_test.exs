defmodule Mokaid.Agents.TransferTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Agents
  alias Mokaid.Agents.Transfer
  alias Mokaid.Billing
  alias Mokaid.Billing.Credits
  alias Mokaid.Knowledge

  alias Mokaid.Knowledge.{
    KnowledgeChunk,
    KnowledgeEdge,
    KnowledgeItem,
    KnowledgeNode,
    KnowledgeNodeChunk
  }

  setup do
    Billing.seed_plans()
    :ok
  end

  defp subscribe!(workspace_id, plan_key) do
    assert {:ok, _} = Billing.change_plan(workspace_id, plan_key)
  end

  defp seed_agent_knowledge!(workspace_id, agent_id) do
    item =
      %KnowledgeItem{}
      |> KnowledgeItem.changeset(%{
        "workspace_id" => workspace_id,
        "agent_id" => agent_id,
        "title" => "Playbook",
        "type" => "note",
        "body" => "Always ship on Friday.",
        "status" => "published",
        "indexing_status" => "indexed",
        "tags" => ["ops"]
      })
      |> Repo.insert!()

    chunk =
      %KnowledgeChunk{}
      |> KnowledgeChunk.changeset(%{
        "workspace_id" => workspace_id,
        "knowledge_item_id" => item.id,
        "chunk_index" => 0,
        "content" => "Always ship on Friday."
      })
      |> Repo.insert!()

    node_a =
      %KnowledgeNode{}
      |> KnowledgeNode.changeset(%{
        "workspace_id" => workspace_id,
        "knowledge_item_id" => item.id,
        "agent_id" => agent_id,
        "key" => "shipping",
        "label" => "Shipping",
        "kind" => "concept"
      })
      |> Repo.insert!()

    node_b =
      %KnowledgeNode{}
      |> KnowledgeNode.changeset(%{
        "workspace_id" => workspace_id,
        "knowledge_item_id" => item.id,
        "agent_id" => agent_id,
        "key" => "friday",
        "label" => "Friday",
        "kind" => "term"
      })
      |> Repo.insert!()

    %KnowledgeEdge{}
    |> KnowledgeEdge.changeset(%{
      "workspace_id" => workspace_id,
      "knowledge_item_id" => item.id,
      "source_node_id" => node_a.id,
      "target_node_id" => node_b.id,
      "relation" => "happens_on"
    })
    |> Repo.insert!()

    %KnowledgeNodeChunk{}
    |> KnowledgeNodeChunk.changeset(%{
      "workspace_id" => workspace_id,
      "node_id" => node_a.id,
      "chunk_id" => chunk.id
    })
    |> Repo.insert!()

    item
  end

  describe "copy_agent/4" do
    test "clones the agent and its knowledge, debiting the target workspace" do
      user = user_fixture()
      {ws_a, _} = workspace_fixture(user)
      {ws_b, _} = workspace_fixture(user)
      subscribe!(ws_b.id, "starter")
      assert {:ok, _} = Credits.add_purchased(ws_b.id, 5_000, description: "transfer budget")

      {:ok, agent} =
        Agents.create_agent(ws_a.id, %{
          "kind" => "ai",
          "display_name" => "Sage",
          "archetype_key" => "developer"
        })

      item = seed_agent_knowledge!(ws_a.id, agent.id)

      spendable_before = Credits.summary(ws_b.id).spendable

      assert {:ok, clone} = Transfer.copy_agent(ws_a.id, agent.id, ws_b.id, user)

      assert clone.workspace_id == ws_b.id
      assert clone.display_name == "Sage"
      assert clone.kind == "ai"
      assert clone.status == "idle"
      assert clone.level == agent.level
      assert clone.skills == agent.skills
      assert clone.slug != agent.slug
      assert get_in(clone.capabilities, ["transferred_from", "agent_id"]) == agent.id
      refute Map.has_key?(clone.capabilities, "training")

      # Original untouched in the source workspace.
      assert Agents.get_agent(ws_a.id, agent.id)

      # One agent's price debited from the destination.
      assert Credits.summary(ws_b.id).spendable ==
               spendable_before - Transfer.transfer_credits()

      # Knowledge copied (Oban runs inline in tests).
      [copied] = Knowledge.list_items(ws_b.id, %{"agent_id" => clone.id})
      assert copied.body == "Always ship on Friday."
      assert copied.metadata["transferred_from_item_id"] == item.id

      chunks = Repo.all(from c in KnowledgeChunk, where: c.knowledge_item_id == ^copied.id)
      assert [%{content: "Always ship on Friday."}] = chunks

      nodes = Repo.all(from n in KnowledgeNode, where: n.knowledge_item_id == ^copied.id)
      assert length(nodes) == 2
      assert Enum.all?(nodes, &(&1.workspace_id == ws_b.id and &1.agent_id == clone.id))

      edges = Repo.all(from e in KnowledgeEdge, where: e.knowledge_item_id == ^copied.id)
      assert length(edges) == 1

      node_ids = Enum.map(nodes, & &1.id)

      links =
        Repo.all(from nc in KnowledgeNodeChunk, where: nc.node_id in ^node_ids)

      assert length(links) == 1
    end

    test "copy_knowledge is idempotent across retries" do
      user = user_fixture()
      {ws_a, _} = workspace_fixture(user)
      {ws_b, _} = workspace_fixture(user)
      subscribe!(ws_b.id, "starter")
      assert {:ok, _} = Credits.add_purchased(ws_b.id, 5_000, description: "transfer budget")

      {:ok, agent} =
        Agents.create_agent(ws_a.id, %{"kind" => "ai", "display_name" => "Sage"})

      seed_agent_knowledge!(ws_a.id, agent.id)

      assert {:ok, clone} = Transfer.copy_agent(ws_a.id, agent.id, ws_b.id, user)

      # Simulate a worker retry after the first successful pass.
      assert :ok = Transfer.copy_knowledge(ws_a.id, agent.id, ws_b.id, clone.id)

      assert length(Knowledge.list_items(ws_b.id, %{"agent_id" => clone.id})) == 1
    end

    test "rejects the copy when the destination has insufficient credits" do
      user = user_fixture()
      {ws_a, _} = workspace_fixture(user)
      {ws_b, _} = workspace_fixture(user)
      subscribe!(ws_b.id, "free")

      {:ok, agent} =
        Agents.create_agent(ws_a.id, %{"kind" => "ai", "display_name" => "Sage"})

      assert {:error, :insufficient_credits} =
               Transfer.copy_agent(ws_a.id, agent.id, ws_b.id, user)

      # Nothing created in the destination.
      assert [] = Agents.list_agents(ws_b.id)
    end

    test "rejects the copy when the destination agent quota is reached" do
      user = user_fixture()
      {ws_a, _} = workspace_fixture(user)
      {ws_b, _} = workspace_fixture(user)
      subscribe!(ws_b.id, "free")
      assert {:ok, _} = Credits.add_purchased(ws_b.id, 10_000, description: "budget")

      {:ok, agent} =
        Agents.create_agent(ws_a.id, %{"kind" => "ai", "display_name" => "Sage"})

      # Free plan allows a single agent — fill the quota.
      {:ok, _} = Agents.create_agent(ws_b.id, %{"kind" => "ai", "display_name" => "Existing"})

      assert {:error, :agent_limit_reached} =
               Transfer.copy_agent(ws_a.id, agent.id, ws_b.id, user)
    end

    test "rejects users who are not members of the destination workspace" do
      user = user_fixture()
      {ws_a, _} = workspace_fixture(user)
      {ws_c, _other_owner} = workspace_fixture()

      {:ok, agent} =
        Agents.create_agent(ws_a.id, %{"kind" => "ai", "display_name" => "Sage"})

      assert {:error, :not_a_member_of_target_workspace} =
               Transfer.copy_agent(ws_a.id, agent.id, ws_c.id, user)
    end

    test "rejects non-AI agents and same-workspace copies" do
      user = user_fixture()
      {ws_a, _} = workspace_fixture(user)
      {ws_b, _} = workspace_fixture(user)
      subscribe!(ws_b.id, "starter")
      assert {:ok, _} = Credits.add_purchased(ws_b.id, 5_000, description: "budget")

      {:ok, human} =
        Agents.create_agent(ws_a.id, %{
          "kind" => "human_linked",
          "display_name" => "Ava",
          "linked_user_id" => user.id
        })

      assert {:error, :only_ai_agents_transferable} =
               Transfer.copy_agent(ws_a.id, human.id, ws_b.id, user)

      assert {:error, :same_workspace} =
               Transfer.copy_agent(ws_a.id, human.id, ws_a.id, user)
    end
  end
end
