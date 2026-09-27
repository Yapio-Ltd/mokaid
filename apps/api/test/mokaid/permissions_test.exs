defmodule Mokaid.PermissionsTest do
  use ExUnit.Case, async: true

  alias Mokaid.Members.{Member, Role}
  alias Mokaid.Permissions

  defp member_with_role(role_name) do
    %Member{role: %Role{name: role_name}}
  end

  test "owner can do everything" do
    owner = member_with_role("Owner")
    assert Permissions.can?(owner, "workspace.delete")
    assert Permissions.can?(owner, "billing.manage")
    assert Permissions.can?(owner, "agents.run_ai")
  end

  test "admin cannot delete the workspace" do
    admin = member_with_role("Admin")
    refute Permissions.can?(admin, "workspace.delete")
    assert Permissions.can?(admin, "members.manage_roles")
  end

  test "viewer is read-only" do
    viewer = member_with_role("Viewer")
    assert Permissions.can?(viewer, "tasks.view")
    refute Permissions.can?(viewer, "tasks.create")
    refute Permissions.can?(viewer, "agents.create")
  end

  test "member without a role has no permissions" do
    refute Permissions.can?(%Member{role: nil}, "tasks.view")
  end

  test "mail mutations require an owner or administrator" do
    for permission <- ~w(mail.send mail.manage) do
      assert permission in Mokaid.Members.permission_keys()

      for role <- ~w(Owner Admin) do
        assert Permissions.can?(member_with_role(role), permission)
      end

      for role <- ["Manager", "Member", "Viewer", "Agent User", "Billing Admin", "Unknown"] do
        refute Permissions.can?(member_with_role(role), permission)
      end

      refute Permissions.can?(%Member{role: nil}, permission)
    end
  end

  test "authorize returns forbidden error tuple" do
    assert {:error, :forbidden} =
             Permissions.authorize(member_with_role("Viewer"), "workspace.delete")

    assert :ok = Permissions.authorize(member_with_role("Owner"), "workspace.delete")
  end
end
