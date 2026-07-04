defmodule MokaidWeb.LeaveRequestController do
  use MokaidWeb, :controller

  alias Mokaid.Calendar
  alias Mokaid.Members
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, params) do
    member = current_member(conn)

    filters =
      if Permissions.can?(member, "leave_requests.view_all") do
        params
      else
        Map.put(params, "member_id", member.id)
      end

    with :ok <- Permissions.authorize(member, "leave_requests.view_own") do
      requests = Members.list_leave_requests(workspace_id(conn), filters)
      json(conn, %{data: Enum.map(requests, &Serializer.leave_request/1)})
    end
  end

  def create(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "leave_requests.create"),
         {:ok, request} <-
           Members.create_leave_request(workspace_id(conn), current_member(conn), params) do
      Mokaid.Realtime.broadcast_workspace(workspace_id(conn), "leave_request.created", %{
        leave_request_id: request.id
      })

      conn
      |> put_status(:created)
      |> json(%{data: Serializer.leave_request(request)})
    end
  end

  def approve(conn, %{"id" => id} = params) do
    decide(conn, id, "approved", params["note"])
  end

  def reject(conn, %{"id" => id} = params) do
    decide(conn, id, "rejected", params["note"])
  end

  defp decide(conn, id, status, note) do
    with :ok <- Permissions.authorize(current_member(conn), "leave_requests.approve"),
         %{} = request <- Members.get_leave_request(workspace_id(conn), id),
         {:ok, updated} <-
           Members.review_leave_request(request, status, current_member(conn), note) do
      if status == "approved" do
        member_name =
          case request.member do
            %{user: %{full_name: name}} -> name
            _ -> "Member"
          end

        Calendar.create_leave_event(updated, member_name)
      end

      Mokaid.Realtime.broadcast_workspace(workspace_id(conn), "leave_request.#{status}", %{
        leave_request_id: updated.id
      })

      json(conn, %{
        data: Serializer.leave_request(Members.get_leave_request(workspace_id(conn), updated.id))
      })
    end
  end
end
