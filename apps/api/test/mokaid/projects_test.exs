defmodule Mokaid.ProjectsTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.{Agents, Projects, Repo, Tasks}
  alias Mokaid.Tasks.Task

  import Mokaid.Fixtures

  describe "update_project/3" do
    test "renames a project" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, project} =
        Projects.create_project(workspace.id, %{"name" => "Alpha"}, member)

      assert {:ok, updated} =
               Projects.update_project(project, %{"name" => "Beta"}, member)

      assert updated.name == "Beta"
    end
  end

  describe "delete_project/1" do
    test "deletes the project and all associated tasks" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, project} =
        Projects.create_project(workspace.id, %{"name" => "Doomed"}, member)

      {:ok, task} =
        Tasks.create_task(
          workspace.id,
          %{
            "title" => "Ship it",
            "project_id" => project.id
          },
          member
        )

      assert {:ok, _} = Projects.delete_project(project)

      assert Projects.get_project(workspace.id, project.id) == nil
      assert Repo.get(Task, task.id) == nil
    end
  end

  describe "add_agent/2 and remove_agent/2" do
    test "assigns a workspace agent idempotently, then removes it" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, project} = Projects.create_project(workspace.id, %{"name" => "Alpha"}, member)

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Bot"})

      assert {:ok, _} = Projects.add_agent(project, agent.id)
      assert {:ok, _} = Projects.add_agent(project, agent.id)

      reloaded = Projects.get_project(workspace.id, project.id)
      assert Enum.map(reloaded.project_agents, & &1.agent_id) == [agent.id]

      assert :ok = Projects.remove_agent(project, agent.id)
      reloaded = Projects.get_project(workspace.id, project.id)
      assert reloaded.project_agents == []
    end

    test "rejects an agent from another workspace" do
      {workspace_a, owner_a} = workspace_fixture()
      {workspace_b, _owner_b} = workspace_fixture()
      member_a = owner_member(workspace_a, owner_a)

      {:ok, project} = Projects.create_project(workspace_a.id, %{"name" => "Alpha"}, member_a)

      {:ok, foreign_agent} =
        Agents.create_agent(workspace_b.id, %{"kind" => "ai", "display_name" => "Intruder"})

      assert {:error, :agent_not_found} = Projects.add_agent(project, foreign_agent.id)

      reloaded = Projects.get_project(workspace_a.id, project.id)
      assert reloaded.project_agents == []
    end
  end

  describe "task-driven agent assignment" do
    test "creating a project task assigned to an agent links the agent to the project" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, project} = Projects.create_project(workspace.id, %{"name" => "Alpha"}, member)

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Bot"})

      {:ok, _task} =
        Tasks.create_task(
          workspace.id,
          %{
            "title" => "Ship it",
            "project_id" => project.id,
            "assigned_agent_id" => agent.id
          },
          member
        )

      reloaded = Projects.get_project(workspace.id, project.id)
      assert Enum.map(reloaded.project_agents, & &1.agent_id) == [agent.id]
    end

    test "Tasks.assign_task links the agent to the task's project" do
      {workspace, owner} = workspace_fixture()
      member = owner_member(workspace, owner)

      {:ok, project} = Projects.create_project(workspace.id, %{"name" => "Alpha"}, member)

      {:ok, agent} =
        Agents.create_agent(workspace.id, %{"kind" => "ai", "display_name" => "Bot"})

      {:ok, task} =
        Tasks.create_task(
          workspace.id,
          %{"title" => "Unassigned", "project_id" => project.id},
          member
        )

      assert {:ok, _} = Tasks.assign_task(task, agent.id, member)

      reloaded = Projects.get_project(workspace.id, project.id)
      assert Enum.map(reloaded.project_agents, & &1.agent_id) == [agent.id]
    end
  end
end
