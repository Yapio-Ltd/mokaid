defmodule Mokaid.MarketplaceTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Agents
  alias Mokaid.Billing
  alias Mokaid.Billing.Stripe
  alias Mokaid.Marketplace
  alias Mokaid.Marketplace.ConnectAccount
  alias Mokaid.Repo

  setup do
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
    :ok
  end

  defp seller_ready!(workspace) do
    %ConnectAccount{}
    |> ConnectAccount.changeset(%{
      workspace_id: workspace.id,
      stripe_account_id: "acct_test_#{System.unique_integer([:positive])}",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true,
      country: "US"
    })
    |> Repo.insert!()
  end

  defp level_up!(agent, level \\ 10) do
    agent
    |> Ecto.Changeset.change(level: level, xp: 0, xp_for_next_level: 1000)
    |> Repo.update!()
  end

  defp create_ai!(workspace) do
    assert {:ok, agent} =
             Agents.create_agent(workspace.id, %{
               "kind" => "ai",
               "display_name" => "Seller Bot",
               "archetype_key" => "blank"
             })

    agent
  end

  test "refuses listing below level 10" do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)
    seller_ready!(workspace)
    agent = create_ai!(workspace)

    assert {:error, :level_too_low} =
             Marketplace.create_listing(workspace.id, member, %{
               "agent_id" => agent.id,
               "mode" => "sale",
               "price_cents" => 4_900
             })
  end

  test "publishes a sale listing at level 10 and blocks a second open listing" do
    {workspace, owner} = workspace_fixture()
    member = owner_member(workspace, owner)
    seller_ready!(workspace)
    agent = create_ai!(workspace) |> level_up!()

    assert {:ok, listing} =
             Marketplace.create_listing(workspace.id, member, %{
               "agent_id" => agent.id,
               "mode" => "sale",
               "price_cents" => 4_900
             })

    assert listing.mode == "sale"
    assert listing.status == "active"

    assert {:error, :listing_already_open} =
             Marketplace.create_listing(workspace.id, member, %{
               "agent_id" => agent.id,
               "mode" => "rent",
               "rent_billing" => "subscription",
               "price_cents" => 1_900
             })
  end

  test "dev checkout fulfills a sale with a cloned agent and no stripe" do
    {seller_ws, seller} = workspace_fixture()
    {buyer_ws, buyer} = workspace_fixture()
    seller_member = owner_member(seller_ws, seller)
    buyer_member = owner_member(buyer_ws, buyer)
    seller_ready!(seller_ws)

    agent = create_ai!(seller_ws) |> level_up!()

    assert {:ok, listing} =
             Marketplace.create_listing(seller_ws.id, seller_member, %{
               "agent_id" => agent.id,
               "mode" => "sale",
               "price_cents" => 2_500
             })

    assert {:ok, result} =
             Marketplace.start_checkout(buyer_ws.id, buyer_member, buyer, listing.id)

    assert result.fulfilled == true
    assert Agents.list_agents(buyer_ws.id) |> length() == 1
    clone = hd(Agents.list_agents(buyer_ws.id))
    assert clone.display_name == agent.display_name
    assert clone.level == 10
    # Seller still has the original
    assert Agents.get_agent(seller_ws.id, agent.id)
  end

  test "mine marks agents under level 10 as ineligible" do
    {workspace, _owner} = workspace_fixture()
    _agent = create_ai!(workspace)
    rows = Marketplace.list_my_agents(workspace.id)
    assert length(rows) == 1
    refute hd(rows).eligible
    assert hd(rows).levels_remaining == 9
  end

  test "application fee is 15 percent" do
    assert Marketplace.fee_percent() == 15
    assert Marketplace.application_fee_cents(10_000) == 1_500
  end
end

defmodule Mokaid.Billing.StripeMarketplaceTest do
  use ExUnit.Case, async: false

  alias Mokaid.Billing.Stripe

  setup do
    previous = Application.get_env(:mokaid, :stripe)

    Application.put_env(:mokaid, :stripe,
      secret_key: "sk_test_xxx",
      publishable_key: "pk_test_xxx",
      webhook_secret: "whsec_test",
      currency: "usd",
      web_base_url: "https://app.example.com"
    )

    on_exit(fn -> Application.put_env(:mokaid, :stripe, previous) end)
    :ok
  end

  test "marketplace payment form includes application fee and destination" do
    form =
      Stripe.marketplace_payment_form(%{
        order_id: "11111111-1111-1111-1111-111111111111",
        listing_id: "22222222-2222-2222-2222-222222222222",
        amount_cents: 4_900,
        application_fee_cents: 735,
        description: "Buy agent",
        destination: "acct_seller",
        buyer_email: "buyer@example.com",
        buyer_workspace_id: "ws-buyer",
        seller_workspace_id: "ws-seller"
      })

    assert form["mode"] == "payment"
    assert form["metadata[kind]"] == "marketplace"
    assert form["payment_intent_data[application_fee_amount]"] == 735
    assert form["payment_intent_data[transfer_data][destination]"] == "acct_seller"
    assert form["success_url"] =~ "/marketplace/return?checkout=success"
  end

  test "marketplace subscription form includes fee percent and destination" do
    form =
      Stripe.marketplace_subscription_form(%{
        order_id: "11111111-1111-1111-1111-111111111111",
        listing_id: "22222222-2222-2222-2222-222222222222",
        amount_cents: 1_900,
        application_fee_percent: 15,
        description: "Rent agent",
        destination: "acct_seller",
        buyer_workspace_id: "ws-buyer",
        seller_workspace_id: "ws-seller"
      })

    assert form["mode"] == "subscription"
    assert form["subscription_data[application_fee_percent]"] == 15
    assert form["subscription_data[transfer_data][destination]"] == "acct_seller"
    assert form["line_items[0][price_data][recurring][interval]"] == "month"
  end
end
