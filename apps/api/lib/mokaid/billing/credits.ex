defmodule Mokaid.Billing.Credits do
  @moduledoc """
  AI credits — the metered currency users spend (ElevenLabs-style).

  Conversion: real LLM cost (`cost_cents`) → credits via a fixed margin
  multiplier. At 10x, 1 cent of real cost bills as 1 credit; a 1000-credit
  pack sells for $19, so 1 credit ≈ $0.019 sold vs $0.001 cost — ~90% margin.

  Balance model:
  - `included_credits_remaining` — the plan's monthly grant, reset each period.
  - `credits_balance` — purchased top-up packs; never expire.
  Spend draws from included first, then balance. Balance may go negative when a
  task already in flight overruns (we never kill running work); the debt is
  settled on the next top-up. New tasks are blocked once the spendable total
  hits zero, unless auto-recharge is on.
  """

  import Ecto.Query

  alias Mokaid.Billing.{CreditTransaction, Subscription}
  alias Mokaid.Realtime
  alias Mokaid.Repo

  # Credits billed per cent of real LLM cost. 10 credits ≈ $0.19 sold for
  # ~$0.10 cost tier — but since cost_cents is already the real cost in cents,
  # ratio 1.0 means 1 credit per cent (10x margin on the $19/1000 pack).
  @credits_per_cent 1.0

  # Minimum credits charged for any billable run, so trivial runs still meter.
  @min_run_credits 1

  @doc "Converts a real LLM cost (in cents) to billable credits."
  def cost_cents_to_credits(cost_cents) when is_integer(cost_cents) and cost_cents > 0 do
    max(@min_run_credits, round(cost_cents * @credits_per_cent))
  end

  def cost_cents_to_credits(_), do: 0

  @doc "Total spendable credits = plan grant remaining + purchased balance."
  def spendable(%Subscription{} = sub) do
    (sub.included_credits_remaining || 0) + (sub.credits_balance || 0)
  end

  def spendable(nil), do: 0

  @doc """
  Whether a workspace may start a NEW AI task. True while it has spendable
  credits, or auto-recharge is armed (a fresh pack will cover it), or the plan
  grants unlimited credits (-1). A negative balance blocks new work but never
  interrupts a task already running.
  """
  def can_start_task?(workspace_id) do
    case get_subscription(workspace_id) do
      # No subscription yet = a workspace that never set up billing. Don't
      # block it — it's implicitly on Free; the subscription is created lazily
      # the first time credits are granted or a plan is chosen.
      nil -> true
      %Subscription{monthly_credits: -1} -> true
      %Subscription{auto_recharge_enabled: true} -> true
      sub -> spendable(sub) > 0
    end
  end

  @doc """
  Charges a completed run's cost to the workspace, records a ledger entry, and
  broadcasts the new balance so the UI updates live. Draws from the monthly
  grant first, then the purchased balance (which may go negative). Returns the
  number of credits charged.
  """
  def charge_run(workspace_id, run_id, agent_id, cost_cents) do
    credits = cost_cents_to_credits(cost_cents)
    if credits <= 0, do: :ok, else: do_charge(workspace_id, run_id, agent_id, credits, cost_cents)
  end

  defp do_charge(workspace_id, run_id, agent_id, credits, cost_cents) do
    case get_subscription(workspace_id) do
      nil ->
        {:ok, 0}

      %Subscription{monthly_credits: -1} = sub ->
        # Unlimited plan (Enterprise): meter for analytics, don't decrement.
        record(workspace_id, "spend", -credits, sub,
          run_id: run_id,
          agent_id: agent_id,
          cost_cents: cost_cents,
          metered_only: true
        )

        broadcast(workspace_id, sub)
        {:ok, credits}

      sub ->
        from_included = min(sub.included_credits_remaining || 0, credits)
        from_balance = credits - from_included

        {1, [updated]} =
          Repo.update_all(
            from(s in Subscription, where: s.id == ^sub.id, select: s),
            inc: [
              included_credits_remaining: -from_included,
              credits_balance: -from_balance
            ]
          )

        record(workspace_id, "spend", -credits, updated,
          run_id: run_id,
          agent_id: agent_id,
          cost_cents: cost_cents
        )

        broadcast(workspace_id, updated)
        maybe_auto_recharge(updated)
        {:ok, credits}
    end
  end

  @doc """
  Adds purchased credits to the balance. If the balance was negative (debt
  from an overrun), the top-up settles it first — the user effectively pays
  the debt plus the new pack.
  """
  def add_purchased(workspace_id, credits, opts \\ []) when is_integer(credits) and credits > 0 do
    case get_subscription(workspace_id) do
      nil ->
        {:error, :no_subscription}

      sub ->
        {1, [updated]} =
          Repo.update_all(
            from(s in Subscription, where: s.id == ^sub.id, select: s),
            inc: [credits_balance: credits]
          )

        record(workspace_id, Keyword.get(opts, :kind, "purchase"), credits, updated,
          description: Keyword.get(opts, :description),
          cost_cents: Keyword.get(opts, :cost_cents, 0)
        )

        broadcast(workspace_id, updated)
        {:ok, updated}
    end
  end

  @doc "Resets the plan's monthly credit grant at the start of a new period."
  def grant_monthly(%Subscription{} = sub) do
    grant = sub.monthly_credits || 0

    {1, [updated]} =
      Repo.update_all(
        from(s in Subscription, where: s.id == ^sub.id, select: s),
        set: [included_credits_remaining: grant, credits_period_start: DateTime.utc_now()]
      )

    if grant > 0,
      do:
        record(sub.workspace_id, "plan_grant", grant, updated,
          description: "Monthly credit grant"
        )

    broadcast(sub.workspace_id, updated)
    {:ok, updated}
  end

  @doc "Overview numbers for the billing UI."
  def summary(workspace_id) do
    case get_subscription(workspace_id) do
      nil ->
        %{included_remaining: 0, balance: 0, spendable: 0, monthly_credits: 0, unlimited: false}

      sub ->
        %{
          included_remaining: sub.included_credits_remaining || 0,
          balance: sub.credits_balance || 0,
          spendable: spendable(sub),
          monthly_credits: sub.monthly_credits || 0,
          unlimited: sub.monthly_credits == -1,
          auto_recharge_enabled: sub.auto_recharge_enabled,
          auto_recharge_pack_key: sub.auto_recharge_pack_key,
          auto_recharge_threshold: sub.auto_recharge_threshold
        }
    end
  end

  def recent_transactions(workspace_id, limit \\ 30) do
    Repo.all(
      from t in CreditTransaction,
        where: t.workspace_id == ^workspace_id,
        order_by: [desc: t.inserted_at],
        limit: ^limit
    )
  end

  ## ---------- Internals ----------

  defp maybe_auto_recharge(%Subscription{auto_recharge_enabled: true} = sub) do
    threshold = sub.auto_recharge_threshold || 0

    if spendable(sub) <= threshold and is_binary(sub.auto_recharge_pack_key) do
      # Fire-and-forget: the payment worker charges the stored method and
      # credits the pack (settling any negative balance in the process).
      %{workspace_id: sub.workspace_id, pack_key: sub.auto_recharge_pack_key}
      |> Mokaid.Billing.Workers.AutoRechargeWorker.new()
      |> Oban.insert()
    end

    :ok
  end

  defp maybe_auto_recharge(_sub), do: :ok

  defp record(workspace_id, kind, amount, sub, opts) do
    unless Keyword.get(opts, :metered_only, false) do
      %CreditTransaction{}
      |> CreditTransaction.changeset(%{
        "workspace_id" => workspace_id,
        "kind" => kind,
        "amount" => amount,
        "cost_cents" => Keyword.get(opts, :cost_cents, 0),
        "balance_after" => spendable(sub),
        "run_id" => Keyword.get(opts, :run_id),
        "agent_id" => Keyword.get(opts, :agent_id),
        "description" => Keyword.get(opts, :description)
      })
      |> Repo.insert()
    end
  end

  defp broadcast(workspace_id, sub) do
    Realtime.broadcast_workspace(workspace_id, "credits.updated", %{
      spendable: spendable(sub),
      included_remaining: sub.included_credits_remaining || 0,
      balance: sub.credits_balance || 0
    })
  end

  defp get_subscription(workspace_id) do
    Repo.one(from s in Subscription, where: s.workspace_id == ^workspace_id)
  end
end
