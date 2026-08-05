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

  # Bare workspace (no bootstrap agent/subscription) so tests control their
  # own agent counts and billing state. Use `bootstrapped_workspace_fixture`
  # to exercise the production signup path.
  def workspace_fixture(owner \\ nil) do
    owner = owner || user_fixture()

    {:ok, workspace} =
      Workspaces.create_workspace(
        %{
          "name" => "Test Workspace",
          "slug" => "test-#{System.unique_integer([:positive])}"
        },
        owner,
        bootstrap: false
      )

    {workspace, owner}
  end

  def bootstrapped_workspace_fixture(owner \\ nil) do
    owner = owner || user_fixture()

    {:ok, workspace} =
      Workspaces.create_workspace(
        %{
          "name" => "Bootstrapped Workspace",
          "slug" => "boot-#{System.unique_integer([:positive])}"
        },
        owner
      )

    {workspace, owner}
  end

  def owner_member(workspace, user) do
    Members.get_member_for_user(workspace.id, user.id)
  end
end
