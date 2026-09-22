defmodule MokaidWeb.MarketplaceControllerTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.Agents
  alias Mokaid.Billing
  alias Mokaid.Marketplace
  alias Mokaid.Marketplace.ConnectAccount
  alias Mokaid.Repo

  setup %{conn: conn} do
    Billing.seed_plans()

    previous = Application.get_env(:mokaid, :stripe)

    Application.put_env(:mokaid, :stripe,
      secret_key: "",
      publishable_key: "",
      webhook_secret: "CHANGE_ME",
      currency: "usd",
      web_base_url: "https://app.example.com"
    )

    on_exit(fn -> Application.put_env(:mokaid, :stripe, previous) end)

    {workspace, owner} = workspace_fixture()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> Mokaid.Auth.Token.sign(owner.id))
      |> put_req_header("x-workspace-id", workspace.id)

    {:ok, conn: conn, workspace: workspace, owner: owner}
  end

  test "POST listing rejects level below 10", %{conn: conn, workspace: workspace} do
    %ConnectAccount{}
    |> ConnectAccount.changeset(%{
      workspace_id: workspace.id,
      stripe_account_id: "acct_ctrl_1",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true,
      country: "US"
    })
    |> Repo.insert!()

    {:ok, agent} =
      Agents.create_agent(workspace.id, %{
        "kind" => "ai",
        "display_name" => "Junior",
        "archetype_key" => "blank"
      })

    conn =
      post(conn, "/api/marketplace/listings", %{
        "agent_id" => agent.id,
        "mode" => "sale",
        "price_cents" => 5000
      })

    assert json_response(conn, 422)["error"]["code"] == "level_too_low"
  end

  test "GET mine returns eligibility flags", %{conn: conn, workspace: workspace} do
    {:ok, _agent} =
      Agents.create_agent(workspace.id, %{
        "kind" => "ai",
        "display_name" => "Trainee",
        "archetype_key" => "blank"
      })

    conn = get(conn, "/api/marketplace/mine")
    body = json_response(conn, 200)
    assert body["meta"]["min_level"] == Marketplace.min_level()
    assert [row] = body["data"]
    assert row["eligible"] == false
    assert row["levels_remaining"] == 9
  end
end
