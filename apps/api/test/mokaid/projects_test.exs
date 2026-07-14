defmodule Mokaid.ProjectsTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.{Projects, Repo, Tasks}
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
        Tasks.create_task(workspace.id, %{
          "title" => "Ship it",
          "project_id" => project.id
        }, member)

      assert {:ok, _} = Projects.delete_project(project)

      assert Projects.get_project(workspace.id, project.id) == nil
      assert Repo.get(Task, task.id) == nil
    end
  end
end
