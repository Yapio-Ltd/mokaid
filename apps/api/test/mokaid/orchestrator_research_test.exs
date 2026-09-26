defmodule Mokaid.AI.OrchestratorResearchTest do
  use ExUnit.Case, async: true

  alias Mokaid.AI.Orchestrator

  test "SEO research and its written report form one mission" do
    for instruction <- [
          "Recherche l'indexation Google du site internet mokaid.com et rédige un rapport",
          "Research and report Google indexation and SEO visibility status of the website mokaid.com",
          "Crée un rapport SEO sur le site internet mokaid.com",
          "Create a report on the website SEO and indexing",
          "Audit du site internet mokaid.com et rapport de synthèse"
        ] do
      refute Orchestrator.composite?(instruction), instruction
    end
  end

  test "research plus synthesis alone is not a pair of independent deliverables" do
    refute Orchestrator.composite?("Recherche les concurrents et rédige un rapport")
    refute Orchestrator.composite?("Market research and a written report")
  end

  test "genuine website builds and independent deliverables remain composite" do
    for instruction <- [
          "Full branding + website + research report for our launch",
          "Je veux le branding complet, le site internet complet et un CRM admin",
          "Audit SEO, puis refais le site internet et le branding",
          "Research SEO and rebuild the website, then deliver a report",
          "Build an SEO optimized website and brand identity",
          "Audit SEO et création d'un site internet avec un rapport"
        ] do
      assert Orchestrator.composite?(instruction), instruction
    end
  end
end
