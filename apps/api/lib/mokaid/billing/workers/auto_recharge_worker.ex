defmodule Mokaid.Billing.Workers.AutoRechargeWorker do
  @moduledoc """
  Auto-recharge: buys an AI credit pack automatically when a workspace's
  spendable balance falls below its threshold (ElevenLabs-style). Charges the
  stored PayMe payment method via a buyer-key sale; on success the pack's
  credits are added (settling any negative balance in the process).

  Unique per workspace within a short window so a burst of spends doesn't fire
  multiple recharges.
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:workspace_id]]

  require Logger

  alias Mokaid.Billing
  alias Mokaid.Billing.Credits

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workspace_id" => workspace_id, "pack_key" => pack_key}}) do
    pack = Billing.get_credit_pack(pack_key)
    subscription = Billing.get_subscription(workspace_id)

    cond do
      pack == nil ->
        Logger.warning("auto_recharge_unknown_pack #{pack_key}")
        :ok

      subscription == nil or not subscription.auto_recharge_enabled ->
        # Setting was turned off between enqueue and run — do nothing.
        :ok

      # Still above threshold (an earlier recharge already covered it): skip.
      Credits.spendable(subscription) > (subscription.auto_recharge_threshold || 0) ->
        :ok

      subscription.external_customer_id in [nil, ""] ->
        Logger.warning("auto_recharge_no_payment_method workspace=#{workspace_id}")
        :ok

      true ->
        charge_and_credit(workspace_id, subscription, pack)
    end
  end

  defp charge_and_credit(workspace_id, subscription, pack) do
    case Billing.PayMe.charge_buyer(%{
           buyer_key: subscription.external_customer_id,
           amount_cents: pack.price_cents,
           description: "Mokaid — auto-recharge #{pack.credits} AI credits"
         }) do
      {:ok, _sale} ->
        Credits.add_purchased(workspace_id, pack.credits,
          kind: "auto_recharge",
          description: "Auto-recharge: #{pack.credits} credits",
          cost_cents: pack.price_cents
        )

        Logger.info("auto_recharge_ok workspace=#{workspace_id} credits=#{pack.credits}")
        :ok

      {:error, reason} ->
        Logger.warning("auto_recharge_failed workspace=#{workspace_id} reason=#{inspect(reason)}")
        # Don't retry-storm on a declined card — surface it and stop.
        :ok
    end
  end
end
