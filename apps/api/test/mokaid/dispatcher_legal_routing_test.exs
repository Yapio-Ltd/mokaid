defmodule Mokaid.AI.DispatcherLegalRoutingTest do
  use Mokaid.DataCase, async: false

  alias Mokaid.Agents
  alias Mokaid.AI.Dispatcher
  alias Mokaid.Billing

  setup do
    config = Application.fetch_env!(:mokaid, :ai_worker)
    Application.put_env(:mokaid, :ai_worker, dispatch: :none, url: nil, token: "test-token")
    on_exit(fn -> Application.put_env(:mokaid, :ai_worker, config) end)

    Billing.seed_plans()
    {workspace, _owner} = workspace_fixture()
    Billing.change_plan(workspace.id, "professional")

    {:ok, engineer} =
      Agents.create_agent(workspace.id, %{
        "kind" => "ai",
        "display_name" => "Sira",
        "role_title" => "Software Engineer",
        "archetype_key" => "developer"
      })

    {:ok, legal} =
      Agents.create_agent(workspace.id, %{
        "kind" => "ai",
        "display_name" => "Taya",
        "role_title" => "Legal Specialist",
        "archetype_key" => "legal"
      })

    {:ok, legal} =
      Agents.apply_internal_update(legal, %{
        "skills" =>
          Enum.map(~w(contracts compliance legal-research risk), &%{"name" => &1, "level" => 90})
      })

    %{workspace: workspace, engineer: engineer, legal: legal}
  end

  for {label, instruction} <- [
        {"reported spelling",
         "Fais moi un recap des lois pour les olim hadashim qui ouvrent une societer en israel"},
        {"desktop cached spelling",
         "Fais moi un recap des lois pour les olim hadashim qui ouvrentn une societer en israel"},
        {"corrected accents",
         "Fais-moi un récap des lois pour les olim hadashim qui ouvrent une société en Israël"},
        {"rights",
         "Quels sont les droits des nouveaux immigrants qui créent une entreprise en Israël ?"},
        {"accented legal adjective",
         "Résume les obligations légales des nouveaux immigrants qui ouvrent une société en Israël"},
        {"accented legislation",
         "Explique la législation applicable aux nouveaux immigrants qui créent une entreprise en Israël"},
        {"explicit known legal keyword",
         "Fais un récap juridique pour les olim hadashim qui ouvrent une société en Israël"}
      ] do
    @tag :legal_routing_regression
    test "routes French legal requests to Taya: #{label}", ctx do
      instruction = unquote(instruction)

      assert {:ok, analysis} =
               Dispatcher.analyze(ctx.workspace.id, %{"instruction" => instruction})

      best_agent = Dispatcher.best_agent(ctx.workspace.id, instruction)

      assert "legal" in analysis.domain_categories,
             "Expected legal routing, got #{inspect(analysis.recommendation)}; " <>
               "best_agent=#{inspect(best_agent && best_agent.display_name)}"

      assert analysis.recommendation.mode == "existing_agent"
      assert analysis.recommendation.agent_id == ctx.legal.id
      refute analysis.recommendation.agent_id == ctx.engineer.id
      assert best_agent.id == ctx.legal.id
    end
  end

  defp with_learned_writing_skills(agent) do
    learning = Map.put(agent.capabilities["learning"], "specialty", "document")

    {:ok, agent} =
      Agents.apply_internal_update(agent, %{
        "capabilities" => Map.put(agent.capabilities, "learning", learning),
        "skills" =>
          Enum.map(
            ~w(architecture code-review coding data-analysis debugging editing planning reporting research spreadsheets writing),
            &%{"name" => &1, "level" => 90}
          )
      })

    agent
  end

  test "legal research and a written report still belong to the legal specialist", ctx do
    with_learned_writing_skills(ctx.engineer)

    instruction = """
    Fais une recherche sur les lois et les obligations légales pour les olim hadashim
    qui ouvrent une société en Israël. Fournis un document avec un rapport structuré,
    une analyse, les démarches, les conditions et les sources officielles.
    """

    assert {:ok, analysis} =
             Dispatcher.analyze(ctx.workspace.id, %{"instruction" => instruction})

    assert "legal" in analysis.domain_categories
    assert "data" in analysis.domain_categories
    assert "document" in analysis.domain_categories
    assert "research" in analysis.domain_categories
    assert analysis.recommendation.mode == "existing_agent"
    assert analysis.recommendation.agent_id == ctx.legal.id
    assert Dispatcher.best_agent(ctx.workspace.id, instruction).id == ctx.legal.id
  end

  test "a website for a law firm remains software work", ctx do
    with_learned_writing_skills(ctx.engineer)
    instruction = "Construis un site web pour un cabinet juridique"

    assert {:ok, analysis} =
             Dispatcher.analyze(ctx.workspace.id, %{"instruction" => instruction})

    assert analysis.recommendation.agent_id == ctx.engineer.id
    assert Dispatcher.best_agent(ctx.workspace.id, instruction).id == ctx.engineer.id
  end

  test "concrete analysis of a legal dataset remains data work", ctx do
    with_learned_writing_skills(ctx.engineer)
    instruction = "Analyse ce dataset de statistiques sur les lois et calcule les moyennes"

    assert {:ok, analysis} =
             Dispatcher.analyze(ctx.workspace.id, %{"instruction" => instruction})

    assert "data" in analysis.domain_categories
    assert analysis.recommendation.agent_id == ctx.engineer.id
    assert Dispatcher.best_agent(ctx.workspace.id, instruction).id == ctx.engineer.id
  end

  test "law words are matched at boundaries rather than inside unrelated French words", ctx do
    assert {:ok, analysis} =
             Dispatcher.analyze(ctx.workspace.id, %{
               "instruction" => "Crée un site web de loisirs avec un emploi du temps"
             })

    refute "legal" in analysis.domain_categories
    assert analysis.recommendation.agent_id == ctx.engineer.id
  end

  test "a legal report about data protection remains legal work", ctx do
    with_learned_writing_skills(ctx.engineer)
    instruction = "Fais un rapport de recherche sur les lois de protection des données"

    assert {:ok, analysis} =
             Dispatcher.analyze(ctx.workspace.id, %{"instruction" => instruction})

    assert analysis.recommendation.agent_id == ctx.legal.id
    assert Dispatcher.best_agent(ctx.workspace.id, instruction).id == ctx.legal.id
  end

  test "routes the actual generated legal brief chat_then_dispatch_1 to Taya", ctx do
    with_learned_writing_skills(ctx.engineer)

    instruction =
      "**Mission : Récapitulatif des lois pour les olim hadashim créant une société en Israël**\n\n**Objectif** : Produire un document de référence complet couvrant les obligations légales, les avantages fiscaux, les exigences de conformité et les processus administratifs applicables aux nouveaux immigrants (olim hadashim) qui constituent une entreprise ou société en Israël.\n\n**Domaines à couvrir** :\n1. Statut d'olim hadashim et durée de validité des privilèges associés\n2. Lois d'enregistrement et constitution de société (Private Company, Ltd, Association, etc.)\n3. Obligations fiscales et régime fiscal spécifique aux nouveaux immigrants\n4. Lois du travail et droits des employés\n5. Lois de protection du consommateur et conformité commerciale\n6. Droits d'importation et tarifs douaniers\n7. Lois de propriété intellectuelle applicables\n8. Obligations comptables et audit\n9. Lois sur la confidentialité et la protection des données\n10. Avantages, exemptions ou allègements disponibles pour les olim hadashim entrepreneurs\n\n**Format attendu** : Document structuré, lisible, organisé par thème avec références aux lois principales et points clés d'action.\n\n**Langue** : Français\n\n**Critères d'acceptation** : Couverture complète des domaines essentiels, informations précises et actualisées, format clair et actionnable pour un nouvel immigrant créant une entreprise."

    assert {:ok, analysis} =
             Dispatcher.analyze(ctx.workspace.id, %{"instruction" => instruction})

    assert analysis.recommendation.agent_id == ctx.legal.id,
           "Unexpected generated-brief route: #{inspect(analysis.recommendation)}"

    assert Dispatcher.best_agent(ctx.workspace.id, instruction).id == ctx.legal.id
  end

  test "routes the actual generated legal brief chat_then_dispatch_2 to Taya", ctx do
    with_learned_writing_skills(ctx.engineer)

    instruction =
      "Mission : Préparer un récapitulatif des lois israéliennes pour les nouveaux immigrants (olim hadashim) qui ouvrent une entreprise.\n\nObjectif : Fournir un document complet en français couvrant :\n- Les cadres légaux d'enregistrement d'entreprise en Israël pour les nouveaux immigrants\n- Les avantages et incitations disponibles pour les olim hadashim entrepreneurs\n- Les obligations fiscales et de conformité\n- Les exigences en matière de permis et licenses commerciales\n- Les considérations spéciales concernant le statut d'immigrant\n- Les ressources gouvernementales et points de contact pertinents\n\nLivrables : \n- Document récapitulatif structuré et facile à consulter\n- Sources légales citées\n- Références aux organismes gouvernementaux israéliens compétents\n\nCritères d'acceptation :\n- Information juridique précise et à jour\n- Couverture complète des aspects légaux majeurs\n- Format clair et organisé logiquement\n- Langue française\n\nRéponse en français."

    assert {:ok, analysis} =
             Dispatcher.analyze(ctx.workspace.id, %{"instruction" => instruction})

    assert analysis.recommendation.agent_id == ctx.legal.id,
           "Unexpected generated-brief route: #{inspect(analysis.recommendation)}"

    assert Dispatcher.best_agent(ctx.workspace.id, instruction).id == ctx.legal.id
  end

  test "routes the actual generated legal brief chat_then_dispatch_3 to Taya", ctx do
    with_learned_writing_skills(ctx.engineer)

    instruction =
      "Recherche juridique et récapitulatif : Lois israéliennes pour olim hadashim créant une entreprise\n\nCONTEXTE : L'utilisateur demande un récapitulatif des lois s'appliquant aux nouveaux immigrants (olim hadashim) qui ouvrent une société en Israël.\n\nLIVRABLES :\n- Récapitulatif structuré couvrant au minimum :\n  • Cadre juridique de création d'entreprise (enregistrement, structure légale)\n  • Avantages fiscaux et incitations spécifiques aux olim hadashim\n  • Exigences réglementaires et permis nécessaires\n  • Droits du travail et obligations d'emploi\n  • Obligations de conformité et rapports\n  • Points clés de différenciation avec les entrepreneurs résidents\n\nCRITÈRES D'ACCEPTATION :\n- Information actualisée et fiable\n- Réponse organisée et lisible\n- Sources identifiées\n- Langue : français\n\nDÉPENDANCES : Information juridique actuelle sur la législation israélienne (une recherche externe peut être nécessaire)\n\nLANGAGE DE LIVRAISON : Français"

    assert {:ok, analysis} =
             Dispatcher.analyze(ctx.workspace.id, %{"instruction" => instruction})

    assert analysis.recommendation.agent_id == ctx.legal.id,
           "Unexpected generated-brief route: #{inspect(analysis.recommendation)}"

    assert Dispatcher.best_agent(ctx.workspace.id, instruction).id == ctx.legal.id
  end
end
