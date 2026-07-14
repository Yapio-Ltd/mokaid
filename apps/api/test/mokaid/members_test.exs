defmodule Mokaid.MembersTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Members
  alias Mokaid.Members.Member

  import Mokaid.Fixtures

  describe "workspace membership" do
    test "creator is Owner of the new workspace only" do
      {workspace_a, owner} = workspace_fixture()
      {workspace_b, _} = workspace_fixture(owner)

      member_a = Members.get_member_for_user(workspace_a.id, owner.id)
      member_b = Members.get_member_for_user(workspace_b.id, owner.id)

      assert member_a
      assert member_b
      assert member_a.id != member_b.id
      assert member_a.workspace_id == workspace_a.id
      assert member_b.workspace_id == workspace_b.id
      assert member_a.role.name == "Owner"
      assert member_b.role.name == "Owner"

      assert Enum.map(Members.list_members(workspace_a.id), & &1.id) == [member_a.id]
      assert Enum.map(Members.list_members(workspace_b.id), & &1.id) == [member_b.id]
    end

    test "members of one workspace are not listed in another" do
      {workspace_a, owner_a} = workspace_fixture()
      {workspace_b, owner_b} = workspace_fixture()

      assert length(Members.list_members(workspace_a.id)) == 1
      assert length(Members.list_members(workspace_b.id)) == 1

      [only_a] = Members.list_members(workspace_a.id)
      assert only_a.user_id == owner_a.id

      [only_b] = Members.list_members(workspace_b.id)
      assert only_b.user_id == owner_b.id
    end
  end

  describe "remove_member/2" do
    test "owner can remove a non-owner member of any status" do
      {workspace, owner} = workspace_fixture()
      owner_member = owner_member(workspace, owner) |> Repo.preload(:role)

      other = user_fixture()
      member_role = Members.get_role_by_name(workspace.id, "Member")

      {:ok, target} =
        %Member{}
        |> Member.changeset(%{
          workspace_id: workspace.id,
          user_id: other.id,
          role_id: member_role.id,
          status: "suspended",
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert()

      target = Repo.preload(target, [:role, :user, :linked_agent])

      assert {:ok, removed} = Members.remove_member(owner_member, target)
      assert removed.status == "removed"
      assert Members.list_members(workspace.id) |> Enum.map(& &1.id) == [owner_member.id]
    end

    test "cannot remove yourself" do
      {workspace, owner} = workspace_fixture()
      owner_member = owner_member(workspace, owner) |> Repo.preload(:role)

      assert {:error, :cannot_remove_self} = Members.remove_member(owner_member, owner_member)
    end

    test "admin cannot remove an owner" do
      {workspace, owner} = workspace_fixture()
      owner_member = owner_member(workspace, owner) |> Repo.preload(:role)
      admin_user = user_fixture()
      admin_role = Members.get_role_by_name(workspace.id, "Admin")

      {:ok, admin} =
        %Member{}
        |> Member.changeset(%{
          workspace_id: workspace.id,
          user_id: admin_user.id,
          role_id: admin_role.id,
          status: "active",
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert()

      admin = Repo.preload(admin, :role)

      assert {:error, :cannot_remove_owner} = Members.remove_member(admin, owner_member)
    end

    test "owner can remove another owner when more than one remains" do
      {workspace, owner} = workspace_fixture()
      owner_member = owner_member(workspace, owner) |> Repo.preload(:role)
      second_owner_user = user_fixture()
      owner_role = Members.get_role_by_name(workspace.id, "Owner")

      {:ok, second_owner} =
        %Member{}
        |> Member.changeset(%{
          workspace_id: workspace.id,
          user_id: second_owner_user.id,
          role_id: owner_role.id,
          status: "active",
          joined_at: DateTime.utc_now()
        })
        |> Repo.insert()

      second_owner = Repo.preload(second_owner, [:role, :linked_agent])

      assert {:ok, removed} = Members.remove_member(owner_member, second_owner)
      assert removed.status == "removed"
    end
  end

  describe "cancel_invite/1" do
    test "cancels a pending invite in the workspace" do
      {workspace, owner} = workspace_fixture()
      inviter = owner_member(workspace, owner)

      {:ok, invite} =
        Members.create_invite(workspace.id, %{"email" => "colleague@example.com"}, inviter)

      assert {:ok, canceled} = Members.cancel_invite(invite)
      assert canceled.status == "canceled"
      assert Members.list_pending_invites(workspace.id) == []
    end
  end
end
