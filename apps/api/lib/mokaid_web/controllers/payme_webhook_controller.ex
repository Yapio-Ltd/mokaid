defmodule MokaidWeb.PaymeWebhookController do
  @moduledoc """
  Public callback endpoint for PayMe hosted payments.

  PayMe POSTs the sale result here (`sale_callback_url`). We reconcile on
  our invoice id (echoed back as `transaction_id`) and verify, in order:

  1. the sale is reported successful,
  2. the invoice exists and the PayMe sale id matches the one stored at
     checkout time,
  3. the seller id in the payload (when present) is ours,
  4. the paid amount (when present) matches the invoice amount.

  Always answers 200 so PayMe doesn't retry indefinitely on business-level
  rejections; genuine anomalies (amount/seller mismatch) are logged at
  error level so they show up in alerting.
  """

  use MokaidWeb, :controller

  require Logger

  alias Mokaid.Billing
  alias Mokaid.Billing.PayMe

  def callback(conn, params) do
    Logger.info("payme_callback sale=#{params["payme_sale_id"]} status=#{params["sale_status"]}")

    case process(params) do
      {:ok, _invoice} ->
        :ok

      {:ignored, reason} ->
        Logger.warning(
          "payme_callback_ignored reason=#{reason} " <>
            inspect(Map.take(params, ~w(payme_sale_id sale_status transaction_id)))
        )

      {:rejected, reason} ->
        # Suspicious payload (wrong seller / wrong amount for a real invoice):
        # log at error level so it trips alerting — this is either an attack
        # or a serious misconfiguration.
        Logger.error(
          "payme_callback_rejected reason=#{reason} " <>
            inspect(Map.take(params, ~w(payme_sale_id sale_status transaction_id sale_price price seller_payme_id)))
        )
    end

    json(conn, %{ok: true})
  end

  defp process(params) do
    with {:completed, true} <- {:completed, PayMe.sale_completed?(params)},
         {:tx, invoice_id} when is_binary(invoice_id) <- {:tx, params["transaction_id"]},
         {:uuid, {:ok, _}} <- {:uuid, Ecto.UUID.cast(invoice_id)},
         {:invoice, %{} = invoice} <- {:invoice, Billing.get_invoice_by_id(invoice_id)},
         {:reference, true} <- {:reference, payment_reference_matches?(invoice, params)},
         {:seller, true} <- {:seller, seller_matches?(params)},
         {:amount, true} <- {:amount, amount_matches?(invoice, params)} do
      Billing.mark_invoice_paid(invoice, %{
        buyer_key: params["buyer_key"],
        card: card_info(params)
      })
    else
      {:completed, false} -> {:ignored, :sale_not_completed}
      {:tx, _} -> {:ignored, :missing_transaction_id}
      {:uuid, _} -> {:ignored, :invalid_transaction_id}
      {:invoice, _} -> {:ignored, :unknown_invoice}
      {:reference, false} -> {:rejected, :sale_id_mismatch}
      {:seller, false} -> {:rejected, :seller_mismatch}
      {:amount, false} -> {:rejected, :amount_mismatch}
    end
  end

  # When checkout stored the PayMe sale id, the callback must carry the same
  # one — a mismatch means the callback doesn't belong to this invoice.
  defp payment_reference_matches?(invoice, params) do
    stored = invoice.external_payment_id
    is_nil(stored) or stored == params["payme_sale_id"]
  end

  # When the payload carries a seller id it must be ours. Payloads without a
  # seller id pass (older callback formats) — the sale id check still holds.
  defp seller_matches?(params) do
    configured = Application.get_env(:mokaid, :payme, [])[:seller_id]
    reported = params["seller_payme_id"] || params["seller_id"]
    is_nil(reported) or reported == "" or reported == configured
  end

  # When the payload carries a price it must match the invoice amount
  # (both in minor units). Prevents a tampered/partial payment from
  # activating a full plan.
  defp amount_matches?(invoice, params) do
    case parse_amount(params["sale_price"] || params["price"]) do
      nil -> true
      amount -> amount == invoice.amount_cents
    end
  end

  defp parse_amount(nil), do: nil
  defp parse_amount(value) when is_integer(value), do: value
  defp parse_amount(value) when is_float(value), do: round(value)

  defp parse_amount(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_amount(_), do: nil

  defp card_info(params) do
    mask = params["buyer_card_mask"] || params["buyer_card"] || ""

    case Regex.run(~r/(\d{4})\s*$/, mask) do
      [_, last4] -> %{"last4" => last4, "brand" => params["card_brand"] || "card"}
      _ -> %{}
    end
  end
end
