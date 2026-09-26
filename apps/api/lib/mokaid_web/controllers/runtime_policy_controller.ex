defmodule MokaidWeb.RuntimePolicyController do
  use MokaidWeb, :controller
  alias Mokaid.AI.RuntimePolicy

  def show(conn, params) do
    with :ok <- same_workspace(conn, params),
         :ok <- Permissions.authorize(current_member(conn), "workspace.view") do
      render_policy(conn)
    end
  end

  def update(conn, params) do
    with :ok <- same_workspace(conn, params),
         {:ok, _} <- RuntimePolicy.update(workspace_id(conn), current_member(conn), params) do
      Mokaid.Audit.log(
        workspace_id(conn),
        current_member(conn),
        "runtime.policy.update",
        "workspace",
        workspace_id(conn),
        Map.take(params, ["enabled", "data_policy_accepted"])
      )

      render_policy(conn)
    else
      {:error, reason} when reason in [:invalid_policy, :data_policy_required] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: to_string(reason),
            message: "Explicit acceptance of US processing and retained session data is required."
          }
        })

      error ->
        error
    end
  end

  defp render_policy(conn) do
    json(conn, %{
      data: RuntimePolicy.public(workspace_id(conn)),
      meta: %{can_update: Permissions.can?(current_member(conn), "workspace.update")}
    })
  end

  defp same_workspace(conn, params) do
    if is_nil(params["id"]) or params["id"] == workspace_id(conn),
      do: :ok,
      else: {:error, :forbidden}
  end
end
