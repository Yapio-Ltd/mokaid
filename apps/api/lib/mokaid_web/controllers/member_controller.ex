defmodule MokaidWeb.MemberController do
  use MokaidWeb, :controller

  alias Mokaid.Agents
  alias Mokaid.Audit
  alias Mokaid.Members
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "members.view") do
      members = Members.list_members(workspace_id(conn))
      invites = Members.list_pending_invites(workspace_id(conn))

      json(conn, %{
        data: Enum.map(members, &Serializer.member/1),
        meta: %{
          pending_invites:
            Enum.map(invites, fn i ->
              %{id: i.id, email: i.email, expires_at: i.expires_at, inserted_at: i.inserted_at}
            end)
        }
      })
    end
  end

  def invite(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "members.invite"),
         {:ok, invite} <-
           Members.create_invite(workspace_id(conn), params, current_member(conn)) do
      Audit.log(workspace_id(conn), current_member(conn), "member.invite", "invite", invite.id, %{
        email: invite.email
      })

      conn
      |> put_status(:created)
      |> json(%{data: %{id: invite.id, email: invite.email, expires_at: invite.expires_at}})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "members.update"),
         %{} = member <- Members.get_member(workspace_id(conn), id),
         {:ok, updated} <- Members.update_member(member, params) do
      if params["role_id"] do
        Audit.log(
          workspace_id(conn),
          current_member(conn),
          "member.role_changed",
          "member",
          id,
          %{role_id: params["role_id"]}
        )
      end

      json(conn, %{data: Serializer.member(Members.get_member(workspace_id(conn), updated.id))})
    end
  end

  def link_agent(conn, %{"id" => id, "agent_id" => agent_id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.link_user"),
         %{} = member <- Members.get_member(workspace_id(conn), id),
         %{} = agent <- Agents.get_agent(workspace_id(conn), agent_id),
         {:ok, updated} <-
           Agents.link_user(agent, member.user_id, member.id, current_member(conn)) do
      json(conn, %{data: Serializer.agent(updated)})
    end
  end
end
