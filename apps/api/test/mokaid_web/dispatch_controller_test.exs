defmodule MokaidWeb.DispatchControllerTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.Members.{Member, Role}
  alias MokaidWeb.{DispatchController, FallbackController}

  test "creating a mission cannot bypass integration grant permissions", %{conn: conn} do
    member = %Member{role: %Role{name: "Manager"}}
    conn = assign(conn, :current_member, member)

    assert {:error, :forbidden} =
             DispatchController.confirm(conn, %{
               "instruction" => "Prepare a report",
               "grant_installation_ids" => [Ecto.UUID.generate()]
             })
  end

  test "creating a specialist requires permission to create employees", %{conn: conn} do
    member = %Member{role: %Role{name: "Member"}}
    conn = assign(conn, :current_member, member)

    assert {:error, :forbidden} =
             DispatchController.confirm(conn, %{
               "instruction" => "Prepare a report",
               "custom_agent" => %{"display_name" => "Writer", "archetype_key" => "writer"}
             })
  end

  test "draft confirmations preserve the response contract and replay identity", %{conn: conn} do
    {workspace, user} = workspace_fixture()

    conn =
      conn
      |> assign(:current_member, owner_member(workspace, user))
      |> assign(:current_workspace_id, workspace.id)

    params = %{
      "instruction" => "Prepare a report",
      "start_now" => false,
      "client_request_id" => Ecto.UUID.generate()
    }

    first = DispatchController.confirm(conn, params) |> json_response(201)
    replay = DispatchController.confirm(conn, params) |> json_response(201)

    assert first["data"]["task"]["id"] == replay["data"]["task"]["id"]
    assert first["data"]["agent"] == nil
    assert first["data"]["run_id"] == nil
  end

  test "missing inputs and attachments produce actionable errors", %{conn: conn} do
    for code <- [:empty_request, :invalid_attachments, :agent_unavailable, :request_id_conflict] do
      body = FallbackController.call(conn, {:error, code}) |> json_response(422)
      assert body["error"]["code"] == to_string(code)
      assert is_binary(body["error"]["message"])
    end
  end
end
