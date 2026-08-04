defmodule Mokaid.AI.OrchestratorTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.AI.Orchestrator
  alias Mokaid.{Agents, Billing, Tasks}

  setup do
    Billing.seed_plans()
    :ok
  end

  defp create_agent(workspace_id, name, role, skills) do
    Billing.change_plan(workspace_id, "professional")

    {:ok, agent} =
      Agents.create_agent(workspace_id, %{
        "kind" => "ai",
        "display_name" => name,
        "role_title" => role,
        "archetype_key" => "generalist"
      })

    {:ok, agent} =
      Agents.apply_internal_update(agent, %{
        "skills" => Enum.map(skills, &%{"name" => &1, "level" => 80}),
        "role_title" => role
      })

    agent
  end

  test "composite?/1 needs at least two distinct deliverables" do
    refute Orchestrator.composite?("Change the logo colour")
    refute Orchestrator.composite?("Build a website")

    assert Orchestrator.composite?(
             "Je veux le branding complet, le site internet complet et un CRM admin"
           )

    assert Orchestrator.composite?("Full branding + website + research report for our launch")
  end

  test "launch/4 decomposes into children and starts the first wave only" do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)

    create_agent(workspace.id, "Mia", "Designer", ["branding", "design", "logo"])
    create_agent(workspace.id, "Dev", "Developer", ["react", "website", "code"])
    create_agent(workspace.id, "Sam", "Strategist", ["research", "market"])

    instruction =
      "Je veux une étude de marché, le branding complet et un site internet pour mon marque"

    {:ok, parent} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => "Lancement marque",
          "description" => instruction,
          "metadata" => %{"instruction" => instruction}
        },
        member
      )

    assert {:ok, %{children: children, waves: waves}} =
             Orchestrator.launch(workspace.id, parent, instruction, member)

    assert length(children) >= 3
    assert waves >= 2

    parent = Tasks.get_task(workspace.id, parent.id)
    composite = parent.metadata["composite"]
    assert length(composite["child_ids"]) == length(children)
    assert length(parent.subtasks) == length(children)
    assert parent.status == "in_progress"

    # First-wave children got a run; later waves wait for handoff.
    first_wave_ids = Map.get(composite["waves"], to_string(composite["current_wave"]), [])
    later_ids = composite["child_ids"] -- first_wave_ids

    for id <- first_wave_ids do
      child = Tasks.get_task(workspace.id, id)
      # Wave-1 missions are enqueued when the plan launches.
      assert child.execution_runs != []
    end

    for id <- later_ids do
      child = Tasks.get_task(workspace.id, id)
      assert get_in(child.metadata, ["composite_wave"]) > composite["current_wave"]
    end
  end

  test "maybe_advance/1 hands off artifacts and finishes the parent" do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)
    create_agent(workspace.id, "Mia", "Designer", ["branding", "design"])
    create_agent(workspace.id, "Dev", "Developer", ["website", "react"])

    instruction = "Brand identity logo + complete website landing page"

    {:ok, parent} =
      Tasks.create_task(
        workspace.id,
        %{
          "title" => "Brand + site",
          "description" => instruction,
          "metadata" => %{"instruction" => instruction}
        },
        member
      )

    assert {:ok, %{children: children}} =
             Orchestrator.launch(workspace.id, parent, instruction, member)

    # Force every child into a finished state and advance manually.
    Enum.each(children, fn child ->
      {:ok, _} = Tasks.update_task(child, %{"status" => "in_review", "progress_percent" => 100})
      Orchestrator.maybe_advance(Tasks.get_task(workspace.id, child.id))
    end)

    parent = Tasks.get_task(workspace.id, parent.id)
    assert parent.status == "in_review"
    assert parent.progress_percent == 100
    assert Enum.count(parent.subtasks, & &1.done) == length(children)
  end
end
