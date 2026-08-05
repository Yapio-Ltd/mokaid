defmodule Mokaid.Billing.Tranzila do
  @moduledoc """
  Tranzila payment provider.

  Two flows:

  * Hosted checkout — we build an `iframenew.php` URL on the hosted payment
    page (https://direct.tranzila.com) and redirect the customer there.
    One-time purchases use the standard terminal (`tranmode=A`); subscription
    purchases use the token terminal with `tranmode=AK` so Tranzila charges
    the card *and* returns a reusable `TranzilaTK` token in the notify
    callback. Every parameter we send (including our `invoice_id`) is echoed
    back to `notify_url_address`, which is how the webhook reconciles.

  * Server-side token charge — renewals and auto-recharge POST to the JSON
    API (`https://api.tranzila.com/v1/transaction/credit_card/create`) with
    the stored token in place of the card number. Requests are authenticated
    with HMAC headers (see auth docs).

  Docs: https://docs.tranzila.com/docs/payments-and-billing/authentication
  Amounts in our system are minor units (cents); Tranzila expects decimal
  major units. Configure via `config :mokaid, :tranzila, ...`.
  """

  require Logger

  @hosted_base "https://direct.tranzila.com"
  @api_base "https://api.tranzila.com/v1"

  # Hosted page currency codes (ISO-4217-ish numeric values Tranzila uses).
  @currency_codes %{"ILS" => 1, "NIS" => 1, "USD" => 2, "EUR" => 978, "GBP" => 826}

  def enabled? do
    Enum.all?([:app_key, :secret, :terminal], fn key ->
      value = config()[key]
      is_binary(value) and value != ""
    end)
  end

  ## ---------- Hosted checkout ----------

  @doc """
  Builds the hosted payment page URL the customer is redirected to.

  `mode` is `:one_time` (standard terminal, plain sale) or `:tokenize`
  (token terminal, sale + token creation for future recurring charges).
  `invoice_id` is echoed back in the notify callback for reconciliation.
  """
  def checkout_url(attrs) do
    mode = attrs[:mode] || :one_time

    params =
      %{
        "sum" => format_amount(attrs.amount_cents),
        "currency" => currency_code(),
        "tranmode" => if(mode == :tokenize, do: "AK", else: "A"),
        "invoice_id" => attrs.invoice_id,
        "pdesc" => attrs.description,
        "success_url_address" => return_url(attrs[:return_path], "success"),
        "fail_url_address" => return_url(attrs[:return_path], "failed"),
        "notify_url_address" => notify_url()
      }
      |> maybe_put("email", attrs[:buyer_email])
      |> maybe_put("contact", attrs[:buyer_name])
      |> maybe_put("lang", attrs[:language])

    "#{hosted_base()}/#{terminal_for(mode)}/iframenew.php?" <> URI.encode_query(params)
  end

  @doc "Terminal used for the given checkout mode."
  def terminal_for(:tokenize), do: config()[:token_terminal] || config()[:terminal]
  def terminal_for(_mode), do: config()[:terminal]

  @doc "True when a Tranzila notify payload reports an approved transaction."
  def transaction_approved?(params) do
    to_string(params["Response"] || params["response"] || "") == "000"
  end

  ## ---------- Server-side token charges ----------

  @doc """
  Charges a stored card token (renewals, auto-recharge) — no hosted page.

  Requires the token plus the card expiry captured at checkout time.
  Returns `{:ok, %{transaction_id: ..., token: ..., last4: ...}}` or
  `{:error, reason}`.
  """
  def charge_token(%{token: token, amount_cents: amount, description: description} = attrs) do
    with {:ok, {month, year}} <- expiry(attrs) do
      payload = %{
        terminal_name: terminal_for(:tokenize),
        txn_currency_code: currency(),
        txn_type: "debit",
        card_number: token,
        expire_month: month,
        expire_year: year,
        items: [
          %{
            name: description,
            type: "I",
            unit_price: amount / 100,
            units_number: 1
          }
        ],
        created_by_system: "mokaid"
      }

      request_charge(payload)
    end
  end

  defp expiry(attrs) do
    with month when is_integer(month) and month in 1..12 <- normalize_int(attrs[:expire_month]),
         year when is_integer(year) and year > 0 <- normalize_int(attrs[:expire_year]) do
      # Tranzila expects a 4-digit year; notify payloads carry 2 digits.
      {:ok, {month, if(year < 100, do: 2000 + year, else: year)}}
    else
      _ -> {:error, :missing_card_expiry}
    end
  end

  defp request_charge(payload) do
    url = "#{api_base()}/transaction/credit_card/create"

    case Req.post(url: url, json: payload, headers: auth_headers(), receive_timeout: 30_000) do
      {:ok, %{status: status, body: %{"error_code" => 0} = body}} when status in 200..299 ->
        result = body["transaction_result"] || %{}

        if processor_approved?(result) do
          {:ok,
           %{
             transaction_id: result["transaction_id"],
             token: result["token"],
             last4: result["last_4"],
             card_type: result["card_type_name"]
           }}
        else
          {:error, "declined (processor code #{result["processor_response_code"]})"}
        end

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        Logger.warning(
          "tranzila_charge_rejected error_code=#{inspect(body["error_code"])} message=#{inspect(body["message"])}"
        )

        {:error, body["message"] || "error #{body["error_code"]}"}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("tranzila_charge_http_error status=#{status} body=#{inspect(body)}")
        {:error, :payment_provider_error}

      {:error, reason} ->
        Logger.warning("tranzila_unreachable #{inspect(reason)}")
        {:error, :payment_provider_unreachable}
    end
  end

  defp processor_approved?(result) do
    to_string(result["processor_response_code"] || "") in ["000", "00", "0"]
  end

  @doc """
  Authentication headers for the Tranzila JSON API.

  Per the docs: `access-token = hash_hmac('sha256', app_key, secret <> time <> nonce)`
  (hex-encoded), where `nonce` is an 80-char random hex string.
  """
  def auth_headers(opts \\ []) do
    app_key = opts[:app_key] || config()[:app_key]
    secret = opts[:secret] || config()[:secret]
    time = opts[:time] || System.os_time(:second)
    nonce = opts[:nonce] || generate_nonce()

    access_token =
      :hmac
      |> :crypto.mac(:sha256, secret <> to_string(time) <> nonce, app_key)
      |> Base.encode16(case: :lower)

    [
      {"X-tranzila-api-app-key", app_key},
      {"X-tranzila-api-request-time", to_string(time)},
      {"X-tranzila-api-nonce", nonce},
      {"X-tranzila-api-access-token", access_token}
    ]
  end

  defp generate_nonce do
    40 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  ## ---------- Amounts / helpers ----------

  @doc "Formats minor units as the decimal string the hosted page expects."
  def format_amount(cents) when is_integer(cents) and cents >= 0 do
    "#{div(cents, 100)}.#{cents |> rem(100) |> to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "Parses a Tranzila decimal amount back into minor units (nil if invalid)."
  def parse_amount_cents(value) when is_integer(value), do: value * 100

  def parse_amount_cents(value) when is_binary(value) do
    case Float.parse(value) do
      {amount, ""} -> round(amount * 100)
      _ -> nil
    end
  end

  def parse_amount_cents(value) when is_float(value), do: round(value * 100)
  def parse_amount_cents(_value), do: nil

  defp normalize_int(value) when is_integer(value), do: value

  defp normalize_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_int(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp currency, do: config()[:currency] || "USD"

  defp currency_code, do: Map.get(@currency_codes, currency(), 2)

  defp hosted_base, do: config()[:hosted_base_url] || @hosted_base

  # Tranzila's JSON API root (overridable in tests). Not to be confused with
  # `:api_base_url`, which is *our* public API base used for the notify URL.
  defp api_base, do: config()[:tranzila_api_url] || @api_base

  defp notify_url, do: "#{config()[:api_base_url]}/api/tranzila/notify"

  defp return_url(nil, "success"), do: "#{config()[:web_base_url]}/billing?payment=done"
  defp return_url(nil, _outcome), do: "#{config()[:web_base_url]}/billing?payment=failed"
  defp return_url(path, _outcome), do: "#{config()[:web_base_url]}#{path}"

  defp config, do: Application.get_env(:mokaid, :tranzila, [])
end
