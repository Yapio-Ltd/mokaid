defmodule Mokaid.Members do
  @moduledoc "Workspace members, roles, permissions, teams, invites and leave requests."

  import Ecto.Query

  alias Mokaid.Members.{LeaveRequest, Member, MemberInvite, Permission, Role, Team}
  alias Mokaid.Repo

  @system_roles [
    {"Owner", "Full control of the workspace"},
    {"Admin", "Manage everything except owner-only actions"},
    {"Manager", "Manage their team's agents, members, tasks and projects"},
    {"Member", "Standard workspace member"},
    {"Viewer", "Read-only access"},
    {"Agent User", "Human linked to an agent, personal work view"},
    {"Billing Admin", "Manage billing and subscription"}
  ]

  @permission_keys ~w(
    workspace.view workspace.update workspace.delete
    members.view members.invite members.update members.remove members.manage_roles
    agents.view agents.create agents.update agents.delete agents.link_user agents.assign_task agents.run_ai
    tasks.view tasks.create tasks.update tasks.assign tasks.delete tasks.approve_action
    projects.view projects.create projects.update projects.delete
    knowledge.view knowledge.upload knowledge.update knowledge.delete knowledge.grant_access
    drive.view drive.upload drive.create_folder drive.rename drive.move drive.copy drive.delete
    drive.restore drive.permanent_delete drive.share drive.manage_permissions drive.view_audit
    drive.read_all_project_files drive.ai_grant_access drive.version_restore
    calendar.view calendar.create calendar.update
    leave_requests.create leave_requests.view_own leave_requests.view_all leave_requests.approve
    integrations.view integrations.connect integrations.disconnect integrations.manage
    billing.view billing.manage
    analytics.view analytics.export
    audit.view
  )

  def permission_keys, do: @permission_keys

  ## ---------- Roles & permissions ----------

  def seed_global_permissions do
    now = DateTime.utc_now()

    entries =
      Enum.map(@permission_keys, fn key ->
        %{
          id: Ecto.UUID.generate(),
          key: key,
          description: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Permission, entries, on_conflict: :nothing, conflict_target: :key)
    {:ok, :seeded}
  end

  def seed_system_roles(workspace_id) do
    roles =
      Enum.map(@system_roles, fn {name, description} ->
        Repo.insert!(
          %Role{
            workspace_id: workspace_id,
            name: name,
            description: description,
            is_system: true
          },
          on_conflict: :nothing
        )
      end)

    {:ok, roles}
  end

  def get_role_by_name(workspace_id, name) do
    Repo.get_by(Role, workspace_id: workspace_id, name: name)
  end

  def add_owner(workspace_id, user_id) do
    role = get_role_by_name(workspace_id, "Owner")

    %Member{}
    |> Member.changeset(%{
      workspace_id: workspace_id,
      user_id: user_id,
      role_id: role && role.id,
      status: "active",
      joined_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  ## ---------- Members ----------

  def get_member(workspace_id, id) do
    Repo.one(
      from m in Member,
        where: m.workspace_id == ^workspace_id and m.id == ^id,
        preload: [:user, :role, :team, :linked_agent]
    )
  end

  def get_member_for_user(workspace_id, user_id) do
    Repo.one(
      from m in Member,
        where: m.workspace_id == ^workspace_id and m.user_id == ^user_id and m.status == "active",
        preload: [:role, :linked_agent]
    )
  end

  def list_members(workspace_id) do
    Repo.all(
      from m in Member,
        where: m.workspace_id == ^workspace_id and m.status != "removed",
        preload: [:user, :role, :team, :linked_agent],
        order_by: [asc: m.inserted_at]
    )
  end

  def update_member(%Member{} = member, attrs) do
    member
    |> Member.changeset(Map.merge(attrs, %{"workspace_id" => member.workspace_id}))
    |> Repo.update()
  end

  @doc """
  Removes a member from this workspace (any status). Soft-marks them as
  `removed` so they no longer appear in the workspace roster. Linked agents
  are unlinked. The acting member cannot remove themselves, nor the last Owner.
  """
  def remove_member(%Member{} = actor, %Member{} = member) do
    cond do
      actor.id == member.id ->
        {:error, :cannot_remove_self}

      owner_role?(member) and not owner_role?(actor) ->
        {:error, :cannot_remove_owner}

      owner_role?(member) and count_active_owners(member.workspace_id) <= 1 ->
        {:error, :cannot_remove_last_owner}

      true ->
        Repo.transaction(fn ->
          unlink_member_agent!(member)

          case member
               |> Ecto.Changeset.change(status: "removed")
               |> Repo.update() do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
    end
  end

  defp owner_role?(%Member{role: %{name: "Owner"}}), do: true
  defp owner_role?(%Member{role: %Ecto.Association.NotLoaded{}} = member) do
    member = Repo.preload(member, :role)
    owner_role?(member)
  end
  defp owner_role?(_), do: false

  defp count_active_owners(workspace_id) do
    Repo.aggregate(
      from(m in Member,
        join: r in assoc(m, :role),
        where:
          m.workspace_id == ^workspace_id and m.status == "active" and r.name == "Owner"
      ),
      :count
    )
  end

  defp unlink_member_agent!(%Member{} = member) do
    member = Repo.preload(member, :linked_agent)

    case member.linked_agent do
      %Mokaid.Agents.Agent{} = agent ->
        attrs =
          if agent.kind == "human_linked" do
            [linked_user_id: nil, linked_member_id: nil, kind: "ai"]
          else
            [linked_user_id: nil, linked_member_id: nil]
          end

        agent
        |> Ecto.Changeset.change(attrs)
        |> Repo.update!()

      _ ->
        :ok
    end
  end

  def touch_member_activity(%Member{} = member) do
    member
    |> Ecto.Changeset.change(last_active_at: DateTime.utc_now())
    |> Repo.update()
  end

  ## ---------- Invites ----------

  def create_invite(workspace_id, attrs, invited_by) do
    role_id =
      attrs["role_id"] ||
        case get_role_by_name(workspace_id, "Member") do
          %{id: id} -> id
          _ -> nil
        end

    %MemberInvite{}
    |> MemberInvite.changeset(
      Map.merge(attrs, %{
        "workspace_id" => workspace_id,
        "role_id" => role_id,
        "invited_by_member_id" => invited_by && invited_by.id
      })
    )
    |> Repo.insert()
  end

  def list_pending_invites(workspace_id) do
    Repo.all(
      from i in MemberInvite,
        where: i.workspace_id == ^workspace_id and i.status == "pending",
        order_by: [desc: i.inserted_at]
    )
  end

  def get_invite(workspace_id, id) do
    Repo.one(
      from i in MemberInvite,
        where: i.workspace_id == ^workspace_id and i.id == ^id
    )
  end

  def cancel_invite(%MemberInvite{} = invite) do
    invite
    |> Ecto.Changeset.change(status: "canceled")
    |> Repo.update()
  end

  ## ---------- Teams ----------

  def list_teams(workspace_id) do
    Repo.all(from t in Team, where: t.workspace_id == ^workspace_id, order_by: t.name)
  end

  def create_team(workspace_id, attrs) do
    %Team{}
    |> Team.changeset(Map.put(attrs, "workspace_id", workspace_id))
    |> Repo.insert()
  end

  ## ---------- Leave requests ----------

  def list_leave_requests(workspace_id, filters \\ %{}) do
    from(lr in LeaveRequest,
      where: lr.workspace_id == ^workspace_id,
      preload: [member: :user, reviewed_by_member: :user],
      order_by: [desc: lr.inserted_at]
    )
    |> maybe_filter_member(filters["member_id"])
    |> maybe_filter_status(filters["status"])
    |> Repo.all()
  end

  defp maybe_filter_member(query, nil), do: query
  defp maybe_filter_member(query, member_id), do: where(query, [lr], lr.member_id == ^member_id)

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [lr], lr.status == ^status)

  def create_leave_request(workspace_id, member, attrs) do
    agent_id = member.linked_agent && member.linked_agent.id

    %LeaveRequest{}
    |> LeaveRequest.changeset(
      Map.merge(attrs, %{
        "workspace_id" => workspace_id,
        "member_id" => member.id,
        "agent_id" => agent_id
      })
    )
    |> Repo.insert()
  end

  def get_leave_request(workspace_id, id) do
    Repo.one(
      from lr in LeaveRequest,
        where: lr.workspace_id == ^workspace_id and lr.id == ^id,
        preload: [member: :user]
    )
  end

  def review_leave_request(%LeaveRequest{} = request, status, reviewer, note \\ nil) do
    request
    |> LeaveRequest.review_changeset(%{
      "status" => status,
      "reviewed_by_member_id" => reviewer.id,
      "review_note" => note
    })
    |> Repo.update()
  end
end
