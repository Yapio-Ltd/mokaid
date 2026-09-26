defmodule MokaidWeb.MarketplaceControllerTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.Agents
  alias Mokaid.Billing
  alias Mokaid.Marketplace
  alias Mokaid.Marketplace.ConnectAccount
  alias Mokaid.Marketplace.{Listing, Order}
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

  test "GET purchases exposes persisted fulfillment only for the buyer workspace", %{
    conn: conn,
    workspace: buyer_workspace
  } do
    {seller_workspace, _seller} = workspace_fixture()
    {other_workspace, _other} = workspace_fixture()

    {:ok, source} =
      Agents.create_agent(seller_workspace.id, %{
        "kind" => "ai",
        "display_name" => "Purchased legal agent",
        "archetype_key" => "blank"
      })

    {:ok, clone} =
      Agents.create_agent(buyer_workspace.id, %{
        "kind" => "ai",
        "display_name" => "Purchased legal agent",
        "archetype_key" => "blank"
      })

    listing =
      %Listing{}
      |> Listing.changeset(%{
        workspace_id: seller_workspace.id,
        agent_id: source.id,
        mode: "sale",
        price_cents: 2_900,
        title: "Legal agent"
      })
      |> Repo.insert!()

    order_attrs = %{
      listing_id: listing.id,
      seller_workspace_id: seller_workspace.id,
      buyer_workspace_id: buyer_workspace.id,
      source_agent_id: source.id,
      mode: "sale",
      amount_cents: 2_900
    }

    pending = %Order{} |> Order.changeset(order_attrs) |> Repo.insert!()

    completed =
      %Order{}
      |> Order.changeset(
        Map.merge(order_attrs, %{status: "fulfilled", cloned_agent_id: clone.id})
      )
      |> Repo.insert!()

    %Order{}
    |> Order.changeset(%{order_attrs | buyer_workspace_id: other_workspace.id})
    |> Repo.insert!()

    rows = conn |> get("/api/marketplace/purchases") |> json_response(200) |> Map.fetch!("data")
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1["buyer_workspace_id"] == buyer_workspace.id))
    assert Enum.all?(rows, &(&1["listing"]["agent"]["id"] == source.id))
    assert Enum.find(rows, &(&1["id"] == pending.id))["status"] == "pending"
    assert Enum.find(rows, &(&1["id"] == pending.id))["cloned_agent_id"] == nil
    fulfilled = Enum.find(rows, &(&1["id"] == completed.id))
    assert fulfilled["status"] == "fulfilled"
    assert fulfilled["cloned_agent_id"] == clone.id
  end
end
