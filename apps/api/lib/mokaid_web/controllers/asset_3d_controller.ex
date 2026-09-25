defmodule MokaidWeb.Asset3dController do
  @moduledoc "3D asset catalog (characters, environments, accessories…)."

  use MokaidWeb, :controller

  alias Mokaid.Assets3d
  alias MokaidWeb.JSON, as: Serializer

  def index(conn, params) do
    opts = if params["kind"], do: [kind: params["kind"]], else: []
    assets = Assets3d.list_assets(Keyword.put(opts, :workspace_id, visible_workspace(conn)))
    json(conn, %{data: Enum.map(assets, &Serializer.asset_3d/1)})
  end

  def show(conn, %{"id" => id}) do
    case Assets3d.get_visible_asset(id, visible_workspace(conn)) do
      nil -> {:error, :not_found}
      asset -> json(conn, %{data: Serializer.asset_3d(asset)})
    end
  end

  defp visible_workspace(conn) do
    with [workspace_id] <- get_req_header(conn, "x-workspace-id"),
         {:ok, workspace_id} <- Ecto.UUID.cast(workspace_id),
         %{status: "active"} <-
           Mokaid.Members.get_member_for_user(workspace_id, conn.assigns.current_user.id) do
      workspace_id
    else
      _ -> nil
    end
  end
end
