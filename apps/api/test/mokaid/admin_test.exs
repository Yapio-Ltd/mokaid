defmodule Mokaid.AdminTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Admin
  alias Mokaid.Accounts
  alias Mokaid.Billing
  alias Mokaid.Repo

  setup do
    {workspace, owner} = workspace_fixture()

    admin =
      user_fixture(%{email: "admin#{System.unique_integer([:positive])}@example.com"})
      |> then(fn u ->
        u
        |> Ecto.Changeset.change(is_platform_admin: true)
        |> Repo.update!()
      end)

    {:ok, workspace: workspace, owner: owner, admin: admin}
  end

  test "metrics returns counts", %{workspace: _w} do
    m = Admin.metrics()
    assert is_integer(m.users_total)
    assert m.users_total >= 2
    assert is_integer(m.workspaces_total)
    assert m.workspaces_total >= 1
  end

  test "list_users includes memberships and filters by status", %{owner: owner, admin: admin} do
    result = Admin.list_users(%{"q" => owner.email})
    assert result.total >= 1
    assert Enum.any?(result.data, &(&1.id == owner.id))

    {:ok, _} = Admin.update_user(owner, %{"status" => "suspended"}, admin)
    suspended = Admin.list_users(%{"status" => "suspended"})
    assert Enum.any?(suspended.data, &(&1.id == owner.id))
  end

  test "non-matching search yields empty", %{} do
    result = Admin.list_users(%{"q" => "zzz-no-such-user-99999"})
    assert result.total == 0
  end

  test "cannot demote self as platform admin", %{admin: admin} do
    assert {:error, :cannot_demote_self} =
             Admin.update_user(admin, %{"is_platform_admin" => false}, admin)
  end

  test "update workspace and audit", %{workspace: workspace, admin: admin} do
    assert {:ok, updated} =
             Admin.update_workspace(
               workspace,
               %{"name" => "Renamed HQ", "usage_limits" => %{"agents" => 5}},
               admin
             )

    assert updated.name == "Renamed HQ"
    assert updated.usage_limits["agents"] == 5

    logs = Admin.list_audit_logs(%{"action" => "admin.workspace"})
    assert Enum.any?(logs.data, &(&1.action == "admin.workspace.update"))
  end

  test "adjust credits and list subscriptions", %{workspace: workspace, admin: admin} do
    assert {:ok, _} = Billing.change_plan(workspace.id, "free")
    assert {:ok, sub} = Admin.adjust_credits(workspace.id, 100, admin)
    assert sub.credits_balance >= 100

    subs = Admin.list_subscriptions(%{})
    assert is_list(subs.data)
  end

  test "reset password", %{owner: owner, admin: admin} do
    assert {:ok, _} = Admin.reset_user_password(owner, "new-secure-password-99", admin)
    assert {:ok, _} = Accounts.authenticate_by_password(owner.email, "new-secure-password-99")
  end
end
