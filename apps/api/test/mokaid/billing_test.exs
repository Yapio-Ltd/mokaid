defmodule Mokaid.BillingTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Agents
  alias Mokaid.Billing
  alias Mokaid.Billing.Credits

  setup do
    Billing.seed_plans()
    :ok
  end

  test "catalog exposes free, starter, team and professional" do
    keys = Billing.list_plans() |> Enum.map(& &1.key) |> Enum.sort()
    assert keys == ["free", "professional", "starter", "team"]

    pro = Billing.get_plan_by_key("professional")
    assert pro.limits["agents"] == 9

    team = Billing.get_plan_by_key("team")
    assert team.limits["agents"] == 6
    assert team.limits["credits_monthly"] == 10_000
    assert team.limits["knowledge_graph"] == "workspace"
    assert team.price_cents_monthly == 8_900
    # Ladder stays strictly increasing between Starter and Professional.
    starter = Billing.get_plan_by_key("starter")
    assert starter.price_cents_monthly < team.price_cents_monthly
    assert team.price_cents_monthly < pro.price_cents_monthly
  end

  test "yearly subscriptions get their monthly grant refreshed mid-period" do
    {workspace, _} = workspace_fixture()
    assert {:ok, sub} = Billing.change_plan(workspace.id, "starter", "yearly")

    # Burn part of the grant, then age the credits period past 30 days while
    # the yearly billing period is still running.
    assert {:ok, 500} = Credits.charge_run(workspace.id, nil, nil, 50)

    stale = DateTime.add(DateTime.utc_now(), -31, :day)

    {1, _} =
      Mokaid.Repo.update_all(
        Ecto.Query.from(s in Mokaid.Billing.Subscription, where: s.id == ^sub.id),
        set: [credits_period_start: stale]
      )

    due = Billing.list_subscriptions_due_for_credit_refresh()
    assert Enum.any?(due, &(&1.id == sub.id))

    assert :ok = Mokaid.Billing.Workers.MonthlyCreditsWorker.perform(%Oban.Job{args: %{}})

    assert Credits.summary(workspace.id).included_remaining == 5_000
    # Refreshed subscriptions are no longer due.
    refute Enum.any?(Billing.list_subscriptions_due_for_credit_refresh(), &(&1.id == sub.id))
  end

  test "monthly subscriptions are never picked up by the credit refresh" do
    {workspace, _} = workspace_fixture()
    assert {:ok, sub} = Billing.change_plan(workspace.id, "starter", "monthly")

    stale = DateTime.add(DateTime.utc_now(), -31, :day)

    {1, _} =
      Mokaid.Repo.update_all(
        Ecto.Query.from(s in Mokaid.Billing.Subscription, where: s.id == ^sub.id),
        set: [credits_period_start: stale]
      )

    refute Enum.any?(Billing.list_subscriptions_due_for_credit_refresh(), &(&1.id == sub.id))
  end

  test "cost_cents_to_credits bills 10 credits per cent of real cost" do
    assert Credits.cost_cents_to_credits(1) == 10
    assert Credits.cost_cents_to_credits(37) == 370
    # Trivial runs still meter at least 1 credit; zero/invalid cost bills nothing.
    assert Credits.cost_cents_to_credits(0) == 0
    assert Credits.cost_cents_to_credits(nil) == 0
  end

  test "charge_run draws from the monthly grant and records a described spend" do
    {workspace, _} = workspace_fixture()
    assert {:ok, _} = Billing.change_plan(workspace.id, "starter")

    # 12 cents of real LLM cost → 120 credits at the 10x rate.
    assert {:ok, 120} =
             Credits.charge_run(workspace.id, nil, nil, 12, description: "Direct chat reply")

    assert Credits.summary(workspace.id).included_remaining == 4_880

    [txn | _] = Credits.recent_transactions(workspace.id)
    assert txn.kind == "spend"
    assert txn.amount == -120
    assert txn.description == "Direct chat reply"
  end

  test "agent_limit defaults to free without a subscription" do
    {workspace, _} = workspace_fixture()
    assert Billing.agent_limit(workspace.id) == 1
  end

  test "change_plan refreshes included credits and preserves purchased balance" do
    {workspace, _} = workspace_fixture()
    assert {:ok, free} = Billing.change_plan(workspace.id, "free")
    assert free.included_credits_remaining == 500

    assert {:ok, _} = Credits.add_purchased(workspace.id, 1_000, description: "pack")
    assert {:ok, starter} = Billing.change_plan(workspace.id, "starter")

    assert starter.included_credits_remaining == 5_000
    assert starter.credits_balance == 1_000
    assert Billing.agent_limit(workspace.id) == 3
  end

  test "downgrade does not archive agents but blocks new creations over quota" do
    {workspace, _} = workspace_fixture()
    assert {:ok, _} = Billing.change_plan(workspace.id, "starter")

    for i <- 1..3 do
      assert {:ok, _} =
               Agents.create_agent(workspace.id, %{
                 "kind" => "ai",
                 "display_name" => "Agent #{i}"
               })
    end

    assert {:ok, _} = Billing.change_plan(workspace.id, "free")
    assert length(Agents.list_agents(workspace.id)) == 3
    assert Billing.agent_limit(workspace.id) == 1

    assert {:error, :agent_limit_reached} =
             Agents.create_agent(workspace.id, %{
               "kind" => "ai",
               "display_name" => "Too many"
             })
  end

  test "charge_strict refuses insufficient balance and records agent_boost" do
    {workspace, _} = workspace_fixture()
    assert {:ok, _} = Billing.change_plan(workspace.id, "free")

    assert {:error, :insufficient_credits} =
             Repo.transaction(fn ->
               case Credits.charge_strict(workspace.id, 1_500,
                      kind: "agent_boost",
                      description: "test"
                    ) do
                 {:ok, _, _} = ok -> ok
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert {:ok, _} = Credits.add_purchased(workspace.id, 1_500, description: "pack")

    assert {:ok, {_sub, 1_500}} =
             Repo.transaction(fn ->
               case Credits.charge_strict(workspace.id, 1_500,
                      kind: "agent_boost",
                      description: "Agent boost"
                    ) do
                 {:ok, sub, credits} -> {sub, credits}
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    [txn | _] = Credits.recent_transactions(workspace.id)
    assert txn.kind == "agent_boost"
    assert txn.amount == -1_500

    # Included monthly grant (500) untouched — charge drew from purchased first? Actually draw from included first.
    # From included min(500, 1500)=500, from balance 1000 → included 0, balance 500, spendable 500
    assert Credits.summary(workspace.id).spendable == 500
  end
end
