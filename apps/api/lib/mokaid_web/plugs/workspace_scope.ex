defmodule MokaidWeb.Plugs.WorkspaceScope do
  @moduledoc """
  Resolves the current workspace from the `x-workspace-id` header and
  ensures the authenticated user is an active member. Assigns
  `:current_workspace_id` and `:current_member` (with role preloaded)
  so downstream authorization checks are always scoped.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Mokaid.Members

  def init(opts), do: opts

  def call(conn, _opts) do
    with [workspace_id] <- get_req_header(conn, "x-workspace-id"),
         {:ok, _} <- Ecto.UUID.cast(workspace_id),
         %{} = member <-
           Members.get_member_for_user(workspace_id, conn.assigns.current_user.id) do
      conn
      |> assign(:current_workspace_id, workspace_id)
      |> assign(:current_member, member)
    else
      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "forbidden", message: "Not a member of this workspace"}})
        |> halt()
    end
  end
end
