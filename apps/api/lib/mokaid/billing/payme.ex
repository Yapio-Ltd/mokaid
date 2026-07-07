defmodule Mokaid.Billing.PayMe do
  @moduledoc """
  PayMe (payme.io) payment provider — Hosted Payment Page flow.

  We open a hosted sale (`generate-sale`) and redirect the customer to
  PayMe's secure page; PayMe then POSTs the result to our public callback
  (`sale_callback_url`) and sends the customer back to the app
  (`sale_return_url`). `capture_buyer: true` returns a reusable `buyer_key`
  in the callback for future charges.

  Docs: https://docs.payme.io/docs/payments — amounts are in minor units
  (agorot/cents). Configure via `config :mokaid, :payme, seller_id: ...`.
  """

  require Logger

  @sandbox_url "https://sandbox.payme.io/api"
  @live_url "https://live.payme.io/api"

  def enabled?, do: is_binary(config()[:seller_id]) and config()[:seller_id] != ""

  @doc """
  Opens a hosted payment page. Returns `{:ok, %{sale_url: ..., payme_sale_id: ...}}`.

  `transaction_id` is echoed back in the callback — we pass our invoice id so
  the webhook can reconcile the payment.
  """
  def generate_hosted_sale(attrs) do
    payload =
      %{
        seller_payme_id: config()[:seller_id],
        sale_price: attrs.amount_cents,
        currency: attrs[:currency] || config()[:currency] || "USD",
        product_name: attrs.description,
        sale_type: "sale",
        capture_buyer: true,
        sale_send_notification: true,
        sale_callback_url: callback_url(),
        sale_return_url: return_url(attrs[:return_path]),
        transaction_id: attrs.transaction_id
      }
      |> maybe_put(:sale_email, attrs[:buyer_email])
      |> maybe_put(:sale_name, attrs[:buyer_name])
      |> maybe_put(:language, attrs[:language])

    case Req.post(url: "#{base_url()}/generate-sale", json: payload, receive_timeout: 20_000) do
      {:ok, %{status: status, body: %{"sale_url" => sale_url} = body}}
      when status in 200..299 and is_binary(sale_url) ->
        {:ok, %{sale_url: sale_url, payme_sale_id: body["payme_sale_id"]}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("payme_generate_sale_failed status=#{status} body=#{inspect(body)}")
        {:error, :payment_provider_error}

      {:error, reason} ->
        Logger.warning("payme_unreachable #{inspect(reason)}")
        {:error, :payment_provider_unreachable}
    end
  end

  @doc "True when a PayMe callback payload reports a successful sale."
  def sale_completed?(params) do
    status = to_string(params["sale_status"] || params["status"] || "")
    String.downcase(status) in ["completed", "success", "settled"]
  end

  @doc """
  Charges a stored buyer (tokenized card, `buyer_key`) directly — no hosted
  page. Used by auto-recharge. Returns {:ok, sale} or {:error, reason}.
  """
  def charge_buyer(%{buyer_key: buyer_key, amount_cents: amount, description: description}) do
    payload = %{
      seller_payme_id: config()[:seller_id],
      currency: config()[:currency] || "USD",
      sale_payment_method: "credit-card",
      sale_type: "sale",
      sale_price: to_string(amount),
      product_name: description,
      buyer_key: buyer_key
    }

    case Req.post(url: "#{base_url()}/generate-sale", json: payload, receive_timeout: 20_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if Map.get(body, "status_code", 0) in [0, nil],
          do: {:ok, body},
          else: {:error, body["status_error_details"] || "declined"}

      {:ok, %{status: status, body: body}} ->
        {:error, "http #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp base_url do
    cond do
      config()[:sandbox] -> @sandbox_url
      is_binary(config()[:base_url]) and config()[:base_url] != "" -> config()[:base_url]
      true -> @live_url
    end
  end

  defp callback_url, do: "#{config()[:api_base_url]}/api/payme/callback"

  defp return_url(nil), do: "#{config()[:web_base_url]}/billing?payment=done"
  defp return_url(path), do: "#{config()[:web_base_url]}#{path}"

  defp config, do: Application.get_env(:mokaid, :payme, [])
end
