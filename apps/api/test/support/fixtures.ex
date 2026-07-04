defmodule Mokaid.Fixtures do
  @moduledoc "Test fixtures."

  alias Mokaid.{Accounts, Members, Workspaces}

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user#{System.unique_integer([:positive])}@example.com",
        full_name: "Test User",
        password: "test-password-1234"
      })
      |> Accounts.register_user()

    user
  end

  def workspace_fixture(owner \\ nil) do
    owner = owner || user_fixture()

    {:ok, workspace} =
      Workspaces.create_workspace(
        %{
          "name" => "Test Workspace",
          "slug" => "test-#{System.unique_integer([:positive])}"
        },
        owner
      )

    {workspace, owner}
  end

  def owner_member(workspace, user) do
    Members.get_member_for_user(workspace.id, user.id)
  end
end
