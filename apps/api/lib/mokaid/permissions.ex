defmodule Mokaid.Permissions do
  @moduledoc """
  Server-side authorization. Roles map to permission sets; every sensitive
  action must be checked here — never rely on frontend hiding alone.
  """

  alias Mokaid.Members.Member

  @role_grants %{
    "Owner" => :all,
    "Admin" => {:all_except, ~w(workspace.delete)},
    "Manager" =>
      ~w(workspace.view members.view members.update agents.view agents.create agents.update
         agents.assign_task agents.run_ai tasks.view tasks.create tasks.update tasks.assign
         tasks.approve_action projects.view projects.create projects.update knowledge.view
         knowledge.upload knowledge.update drive.view drive.upload drive.create_folder
         drive.rename drive.move drive.copy drive.delete drive.restore drive.share
         calendar.view calendar.create calendar.update leave_requests.create
         leave_requests.view_own leave_requests.view_all leave_requests.approve
         integrations.view analytics.view notifications.view),
    "Member" => ~w(workspace.view members.view agents.view tasks.view tasks.create tasks.update
         projects.view knowledge.view knowledge.upload drive.view drive.upload
         drive.create_folder drive.rename calendar.view calendar.create
         leave_requests.create leave_requests.view_own integrations.view analytics.view),
    "Viewer" => ~w(workspace.view members.view agents.view tasks.view projects.view knowledge.view
         drive.view calendar.view analytics.view),
    "Agent User" =>
      ~w(workspace.view agents.view tasks.view tasks.update projects.view knowledge.view
         drive.view drive.upload calendar.view leave_requests.create leave_requests.view_own),
    "Billing Admin" => ~w(workspace.view billing.view billing.manage analytics.view)
  }

  @doc "Checks whether a member (with preloaded role) holds a permission key."
  def can?(%Member{role: %{name: role_name}}, permission) when is_binary(permission) do
    case Map.get(@role_grants, role_name) do
      :all -> true
      {:all_except, denied} -> permission not in denied
      grants when is_list(grants) -> permission in grants
      nil -> false
    end
  end

  def can?(_, _), do: false

  def authorize(member, permission) do
    if can?(member, permission), do: :ok, else: {:error, :forbidden}
  end
end
