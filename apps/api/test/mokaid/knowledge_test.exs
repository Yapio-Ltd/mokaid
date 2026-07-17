defmodule Mokaid.KnowledgeTest do
  # async: false — some tests mutate Application env (:ai_worker) and must not
  # race with other suites that dispatch Oban jobs inline.
  use Mokaid.DataCase, async: false

  alias Mokaid.Knowledge

  @dims 1536

  # Deterministic synthetic embeddings: a unit vector concentrated on one
  # axis per "topic", so cosine ranking in tests is fully controlled.
  defp axis_embedding(axis, weight \\ 1.0) do
    List.duplicate(0.0, axis) ++ [weight] ++ List.duplicate(0.0, @dims - axis - 1)
  end

  defp published_item(workspace_id, title, attrs \\ %{}) do
    {:ok, item} =
      Knowledge.create_item(
        workspace_id,
        Map.merge(
          %{"title" => title, "type" => "note", "status" => "published"},
          attrs
        )
      )

    item
  end

  describe "insert_chunks/2 + search_chunks/4 (hybrid retrieval)" do
    setup do
      {workspace, _owner} = workspace_fixture()
      %{workspace: workspace}
    end

    test "semantic search ranks by cosine distance", %{workspace: workspace} do
      item = published_item(workspace.id, "Comptes Q3")

      Knowledge.insert_chunks(item, [
        %{content: "Revenus du troisième trimestre en hausse", embedding: axis_embedding(0)},
        %{content: "Politique de congés payés", embedding: axis_embedding(1)}
      ])

      results = Knowledge.search_chunks(workspace.id, axis_embedding(0), 2)

      assert length(results) == 2
      assert hd(results).chunk.content =~ "Revenus"
      assert hd(results).item_title == "Comptes Q3"
    end

    test "lexical match rescues exact terms the embedding misses", %{workspace: workspace} do
      item = published_item(workspace.id, "Contrats fournisseurs")

      # The chunk containing the SKU is semantically FAR from the query
      # vector (orthogonal axis); only full-text search can find it.
      Knowledge.insert_chunks(item, [
        %{content: "Référence produit XK-4471-B, garantie 24 mois", embedding: axis_embedding(5)},
        %{content: "Conditions générales de vente standard", embedding: axis_embedding(0)}
      ])

      results = Knowledge.search_chunks(workspace.id, axis_embedding(0), 1, query: "XK-4471-B")

      # RRF fusion: found by lexical branch only, still surfaces at the top
      # over the semantically-closest chunk because both branches contribute.
      contents = Enum.map(results, & &1.chunk.content)
      assert Enum.any?(contents, &(&1 =~ "XK-4471-B"))
    end

    test "chunk found by both branches outranks single-branch chunks", %{workspace: workspace} do
      item = published_item(workspace.id, "Rapport médical")

      Knowledge.insert_chunks(item, [
        # Semantically close AND contains the query term.
        %{
          content: "Le patient souffre d'hypertension chronique",
          embedding: axis_embedding(0, 1.0)
        },
        # Semantically closest but no lexical match.
        %{content: "Analyse sanguine dans les normes", embedding: axis_embedding(0, 0.99)},
        # Lexical match only, semantically far.
        %{content: "hypertension mentionnée en passant", embedding: axis_embedding(9)}
      ])

      [top | _] =
        Knowledge.search_chunks(workspace.id, axis_embedding(0), 3, query: "hypertension")

      assert top.chunk.content =~ "patient souffre d'hypertension"
      assert top.score > 0
    end

    test "degrades to pure semantic search without query text", %{workspace: workspace} do
      item = published_item(workspace.id, "Notes")

      Knowledge.insert_chunks(item, [
        %{content: "premier fragment", embedding: axis_embedding(0)}
      ])

      assert [result] = Knowledge.search_chunks(workspace.id, axis_embedding(0), 5)
      assert result.chunk.content == "premier fragment"

      assert [_] = Knowledge.search_chunks(workspace.id, axis_embedding(0), 5, query: "  ")
    end

    test "unpublished items are excluded", %{workspace: workspace} do
      item = published_item(workspace.id, "Brouillon", %{"status" => "draft"})

      Knowledge.insert_chunks(item, [
        %{content: "contenu non publié", embedding: axis_embedding(0)}
      ])

      assert Knowledge.search_chunks(workspace.id, axis_embedding(0), 5) == []
    end

    test "agent-scoped knowledge never leaks to other agents", %{workspace: workspace} do
      Mokaid.Billing.seed_plans()
      assert {:ok, _} = Mokaid.Billing.change_plan(workspace.id, "starter")

      {:ok, agent_record_a} =
        Mokaid.Agents.create_agent(workspace.id, %{
          "kind" => "ai",
          "display_name" => "Agent A",
          "ai_enabled" => true
        })

      {:ok, agent_record_b} =
        Mokaid.Agents.create_agent(workspace.id, %{
          "kind" => "ai",
          "display_name" => "Agent B",
          "ai_enabled" => true
        })

      agent_a = agent_record_a.id
      agent_b = agent_record_b.id

      general = published_item(workspace.id, "Général")
      scoped = published_item(workspace.id, "Privé agent A", %{"agent_id" => agent_a})

      Knowledge.insert_chunks(general, [
        %{content: "connaissance générale", embedding: axis_embedding(0)}
      ])

      Knowledge.insert_chunks(scoped, [
        %{content: "connaissance privée de l'agent A", embedding: axis_embedding(0)}
      ])

      for_a = Knowledge.search_chunks(workspace.id, axis_embedding(0), 5, agent_id: agent_a)
      for_b = Knowledge.search_chunks(workspace.id, axis_embedding(0), 5, agent_id: agent_b)
      general_only = Knowledge.search_chunks(workspace.id, axis_embedding(0), 5)

      assert Enum.any?(for_a, &(&1.chunk.content =~ "privée"))
      refute Enum.any?(for_b, &(&1.chunk.content =~ "privée"))
      refute Enum.any?(general_only, &(&1.chunk.content =~ "privée"))
      assert Enum.any?(for_b, &(&1.chunk.content =~ "générale"))
    end
  end

  describe "mark_indexed/1 and mark_failed/2" do
    setup do
      {workspace, _owner} = workspace_fixture()
      %{workspace: workspace}
    end

    test "mark_indexed publishes the item", %{workspace: workspace} do
      item = published_item(workspace.id, "Doc", %{"status" => "processing"})

      assert {:ok, updated} = Knowledge.mark_indexed(item)
      assert updated.indexing_status == "indexed"
      assert updated.status == "published"
    end

    test "mark_failed stores the error in metadata", %{workspace: workspace} do
      item = published_item(workspace.id, "Corrompu")

      assert {:ok, updated} = Knowledge.mark_failed(item, "unsupported format: .png")
      assert updated.indexing_status == "failed"
      assert updated.status == "failed"
      assert updated.metadata["indexing_error"] =~ "unsupported format"
    end
  end

  describe "ingestion enqueue + worker callback" do
    setup do
      {workspace, _owner} = workspace_fixture()
      %{workspace: workspace}
    end

    test "create_item with body does not stick in indexing when dispatch is :none",
         %{workspace: workspace} do
      assert Application.fetch_env!(:mokaid, :ai_worker)[:dispatch] == :none

      {:ok, item} =
        Knowledge.create_item(workspace.id, %{
          "title" => "Pack skill",
          "type" => "document",
          "body" => "# Skill\n\nDo the thing carefully.",
          "status" => "processing"
        })

      item = Knowledge.get_item(workspace.id, item.id)
      refute item.indexing_status == "indexing"
    end

    test "worker chunk callback stores embeddings and marks indexed",
         %{workspace: workspace} do
      {:ok, item} =
        Knowledge.create_item(workspace.id, %{
          "title" => "Domain pack doc",
          "type" => "document",
          "body" => "Guide for reviewing pull requests on GitHub.",
          "status" => "processing",
          "indexing_status" => "indexing"
        })

      # Simulate AI worker POST /api/worker/knowledge/:id/chunks
      {count, _} =
        Knowledge.replace_chunks(item, [
          %{
            content: "Guide for reviewing pull requests on GitHub.",
            embedding: axis_embedding(3)
          }
        ])

      assert count == 1
      assert {:ok, indexed} = Knowledge.mark_indexed(item)
      assert indexed.indexing_status == "indexed"
      assert indexed.status == "published"

      results = Knowledge.search_chunks(workspace.id, axis_embedding(3), 1)
      assert hd(results).chunk.content =~ "pull requests"
    end

    test "IngestionWorker cancels cleanly when AI worker is disabled",
         %{workspace: workspace} do
      {:ok, item} =
        Knowledge.create_item(workspace.id, %{
          "title" => "Skip me",
          "type" => "document",
          "body" => "text body for ingest",
          "status" => "processing"
        })

      assert {:cancel, :ai_worker_disabled} =
               Mokaid.Knowledge.Workers.IngestionWorker.perform(%Oban.Job{
                 args: %{
                   "knowledge_item_id" => item.id,
                   "workspace_id" => workspace.id
                 }
               })
    end

    test "IngestionWorker marks failed when HTTP URL is missing",
         %{workspace: workspace} do
      {:ok, item} =
        Knowledge.create_item(workspace.id, %{
          "title" => "No URL",
          "type" => "document",
          "body" => "needs embedding",
          "status" => "processing"
        })

      previous = Application.fetch_env!(:mokaid, :ai_worker)

      on_exit(fn ->
        Application.put_env(:mokaid, :ai_worker, previous)
      end)

      Application.put_env(:mokaid, :ai_worker,
        dispatch: :http,
        url: nil,
        token: "test-token"
      )

      assert {:cancel, :ai_worker_url_missing} =
               Mokaid.Knowledge.Workers.IngestionWorker.perform(%Oban.Job{
                 args: %{
                   "knowledge_item_id" => item.id,
                   "workspace_id" => workspace.id
                 }
               })

      failed = Knowledge.get_item(workspace.id, item.id)
      assert failed.indexing_status == "failed"
      assert failed.metadata["indexing_error"] =~ "URL"
    end
  end
end
