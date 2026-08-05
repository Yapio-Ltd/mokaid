defmodule MokaidWeb.TranzilaWebhookController do
  @moduledoc """
  Public notify endpoint for Tranzila hosted payments.

  Tranzila POSTs the transaction result to `notify_url_address` with every
  parameter we originally sent to the payment page (including our
  `invoice_id`) plus the processor response. We reconcile on the invoice id
  and verify, in order:

  1. the transaction is approved (`Response == "000"`),
  2. the invoice exists and is still settleable,
  3. the paid amount (`sum`) matches the invoice amount.

  Subscription checkouts run on the token terminal with `tranmode=AK`, so
  approved payloads carry a reusable `TranzilaTK` token plus the card expiry
  — stored on the subscription for future recurring charges.

  Always answers 200 so Tranzila doesn't retry indefinitely on
  business-level rejections; genuine anomalies (amount mismatch on a real
  invoice) are logged at error level so they show up in alerting.
  """

  use MokaidWeb, :controller

  require Logger

  alias Mokaid.Billing
  alias Mokaid.Billing.Tranzila

  def notify(conn, params) do
    Logger.info(
      "tranzila_notify invoice=#{params["invoice_id"]} response=#{params["Response"]} index=#{params["index"]}"
    )

    case process(params) do
      {:ok, _invoice} ->
        :ok

      {:ignored, reason} ->
        Logger.warning(
          "tranzila_notify_ignored reason=#{reason} " <>
            inspect(Map.take(params, ~w(invoice_id Response index sum)))
        )

      {:rejected, reason} ->
        # Suspicious payload (wrong amount for a real invoice): log at error
        # level so it trips alerting — this is either an attack or a serious
        # misconfiguration.
        Logger.error(
          "tranzila_notify_rejected reason=#{reason} " <>
            inspect(Map.take(params, ~w(invoice_id Response index sum currency)))
        )
    end

    json(conn, %{ok: true})
  end

  defp process(params) do
    with {:approved, true} <- {:approved, Tranzila.transaction_approved?(params)},
         {:tx, invoice_id} when is_binary(invoice_id) <- {:tx, params["invoice_id"]},
         {:uuid, {:ok, _}} <- {:uuid, Ecto.UUID.cast(invoice_id)},
         {:invoice, %{} = invoice} <- {:invoice, Billing.get_invoice_by_id(invoice_id)},
         {:amount, true} <- {:amount, amount_matches?(invoice, params)} do
      if reference = params["index"] do
        Billing.attach_payment_reference(invoice, to_string(reference))
      end

      Billing.mark_invoice_paid(invoice, %{
        buyer_key: token(params),
        card: card_info(params)
      })
    else
      {:approved, false} -> {:ignored, :transaction_not_approved}
      {:tx, _} -> {:ignored, :missing_invoice_id}
      {:uuid, _} -> {:ignored, :invalid_invoice_id}
      {:invoice, _} -> {:ignored, :unknown_invoice}
      {:amount, false} -> {:rejected, :amount_mismatch}
    end
  end

  # When the payload carries an amount it must match the invoice amount.
  # Prevents a tampered/partial payment from activating a full plan.
  defp amount_matches?(invoice, params) do
    case Tranzila.parse_amount_cents(params["sum"]) do
      nil -> true
      amount -> amount == invoice.amount_cents
    end
  end

  defp token(params) do
    case params["TranzilaTK"] do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  # Card metadata stored on the subscription: last4 for display, expiry
  # because the JSON API requires it when charging the token later.
  defp card_info(params) do
    last4 =
      case Regex.run(~r/(\d{4})\s*$/, to_string(params["ccno"] || "")) do
        [_, digits] -> digits
        _ -> nil
      end

    %{}
    |> maybe_put("last4", last4)
    |> maybe_put("brand", params["cardtype_name"] || params["cardtype"])
    |> maybe_put("expire_month", params["expmonth"])
    |> maybe_put("expire_year", params["expyear"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
