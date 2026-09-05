defmodule Mokaid.Billing.Stripe do
  @moduledoc """
  Stripe payment provider.

  * Checkout Sessions — first-time plan purchases (`mode=subscription`) and
    credit-pack sales (`mode=payment`). The hosted page is a full redirect;
    Stripe refuses iframes.
  * Stripe Billing owns recurring charges. We reconcile renewals via webhooks
    rather than charging a stored token ourselves.
  * Off-session PaymentIntents power auto-recharge against the customer's
    default payment method.

  Configure via `config :mokaid, :stripe, ...`. Empty `secret_key` disables
  payments (dev fallback activates plans/credits directly).
  """

  require Logger

  @api_base "https://api.stripe.com/v1"
  @signature_tolerance_sec 300

  def enabled? do
    key = config()[:secret_key]
    is_binary(key) and key != ""
  end

  def webhook_configured? do
    secret = config()[:webhook_secret]
    is_binary(secret) and secret != "" and secret != "CHANGE_ME"
  end

  def publishable_key, do: config()[:publishable_key]

  def currency do
    (config()[:currency] || "usd") |> to_string() |> String.downcase()
  end

  def web_base_url do
    (config()[:web_base_url] || "http://localhost:5173") |> String.trim_trailing("/")
  end

  @doc """
  Builds the form body for a Checkout Session. Public so tests can assert
  the payload without calling Stripe.
  """
  def checkout_form(attrs) do
    kind = attrs[:kind] || "credits"
    {success_url, cancel_url} = return_urls(attrs[:return_path])

    base = %{
      "mode" => if(kind == "subscription", do: "subscription", else: "payment"),
      "success_url" => success_url,
      "cancel_url" => cancel_url,
      "client_reference_id" => attrs[:invoice_id],
      "metadata[invoice_id]" => attrs[:invoice_id],
      "metadata[workspace_id]" => attrs[:workspace_id],
      "metadata[kind]" => kind,
      "line_items[0][quantity]" => 1,
      "line_items[0][price_data][currency]" => currency(),
      "line_items[0][price_data][unit_amount]" => attrs[:amount_cents],
      "line_items[0][price_data][product_data][name]" => attrs[:description]
    }

    base
    |> maybe_put("customer", attrs[:customer_id])
    |> maybe_put("customer_email", if(attrs[:customer_id], do: nil, else: attrs[:buyer_email]))
    |> put_mode_fields(kind, attrs)
    |> reject_nils()
  end

  def create_checkout_session(attrs) do
    request(:post, "/checkout/sessions", checkout_form(attrs))
  end

  def create_portal_session(customer_id, return_url) do
    request(:post, "/billing_portal/sessions", %{
      "customer" => customer_id,
      "return_url" => return_url
    })
  end

  def get_or_create_customer(attrs) do
    case attrs[:customer_id] do
      "cus_" <> _ = id ->
        {:ok, %{"id" => id}}

      _ ->
        request(
          :post,
          "/customers",
          reject_nils(%{
            "email" => attrs[:email],
            "name" => attrs[:name],
            "metadata[workspace_id]" => attrs[:workspace_id]
          })
        )
    end
  end

  def retrieve_subscription(subscription_id) do
    request(:get, "/subscriptions/#{subscription_id}")
  end

  def update_subscription(subscription_id, attrs) do
    with {:ok, sub} <- retrieve_subscription(subscription_id),
         item_id when is_binary(item_id) <- first_item_id(sub) do
      interval = if attrs[:billing_cycle] == "yearly", do: "year", else: "month"

      request(:post, "/subscriptions/#{subscription_id}", %{
        "items[0][id]" => item_id,
        "items[0][price_data][currency]" => currency(),
        "items[0][price_data][unit_amount]" => attrs[:amount_cents],
        "items[0][price_data][product_data][name]" => attrs[:product_name],
        "items[0][price_data][recurring][interval]" => interval,
        "proration_behavior" => "create_prorations",
        "metadata[plan_key]" => attrs[:plan_key],
        "metadata[billing_cycle]" => attrs[:billing_cycle]
      })
    else
      nil -> {:error, :missing_subscription_item}
      other -> other
    end
  end

  def cancel_subscription(subscription_id) when is_binary(subscription_id) do
    request(:delete, "/subscriptions/#{subscription_id}")
  end

  def cancel_subscription(_), do: {:ok, :noop}

  def charge_off_session(attrs) do
    request(
      :post,
      "/payment_intents",
      reject_nils(%{
        "amount" => attrs[:amount_cents],
        "currency" => currency(),
        "customer" => attrs[:customer_id],
        "off_session" => true,
        "confirm" => true,
        "description" => attrs[:description],
        "metadata[workspace_id]" => attrs[:workspace_id],
        "metadata[kind]" => "credits"
      })
    )
  end

  @doc """
  Verifies `Stripe-Signature` and decodes the event JSON.

  Returns `{:error, :webhook_secret_missing}` when the signing secret has
  not been configured yet (endpoint is live, secret comes later).
  """
  def verify_webhook(payload, signature_header) when is_binary(payload) do
    secret = config()[:webhook_secret]

    cond do
      not webhook_configured?() ->
        {:error, :webhook_secret_missing}

      not is_binary(signature_header) or signature_header == "" ->
        {:error, :missing_signature}

      true ->
        verify_signature(payload, signature_header, secret)
    end
  end

  def verify_webhook(_, _), do: {:error, :invalid_payload}

  def stripe_id(nil), do: nil
  def stripe_id(id) when is_binary(id), do: id
  def stripe_id(%{"id" => id}) when is_binary(id), do: id
  def stripe_id(_), do: nil

  def stripe_customer?("cus_" <> _), do: true
  def stripe_customer?(_), do: false

  def stripe_subscription?("sub_" <> _), do: true
  def stripe_subscription?(_), do: false

  ## ---------- internals ----------

  defp put_mode_fields(form, "subscription", attrs) do
    interval = if attrs[:billing_cycle] == "yearly", do: "year", else: "month"

    Map.merge(form, %{
      "line_items[0][price_data][recurring][interval]" => interval,
      "subscription_data[metadata][workspace_id]" => attrs[:workspace_id],
      "subscription_data[metadata][plan_key]" => attrs[:plan_key],
      "subscription_data[metadata][billing_cycle]" => attrs[:billing_cycle],
      "subscription_data[metadata][invoice_id]" => attrs[:invoice_id]
    })
  end

  defp put_mode_fields(form, _kind, _attrs) do
    Map.put(form, "payment_intent_data[setup_future_usage]", "off_session")
  end

  defp return_urls(return_path) do
    base = web_base_url()
    path = sanitize_return_path(return_path)
    {success_join, cancel_join} = query_joins(path)

    {"#{base}#{path}#{success_join}checkout=success",
     "#{base}#{path}#{cancel_join}checkout=canceled"}
  end

  defp sanitize_return_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "//") -> "/billing"
      String.starts_with?(path, "/") -> path
      true -> "/billing"
    end
  end

  defp sanitize_return_path(_), do: "/billing"

  defp query_joins(path) do
    if String.contains?(path, "?"), do: {"&", "&"}, else: {"?", "?"}
  end

  defp verify_signature(payload, header, secret) do
    parts =
      header
      |> String.split(",")
      |> Enum.reduce(%{}, fn
        "t=" <> t, acc -> Map.put(acc, :t, t)
        "v1=" <> v, acc -> Map.put(acc, :v1, v)
        _, acc -> acc
      end)

    with {:ok, timestamp} <- parse_timestamp(parts[:t]),
         :ok <- check_tolerance(timestamp),
         expected <- hmac(secret, "#{timestamp}.#{payload}"),
         true <- secure_compare(expected, parts[:v1]),
         {:ok, event} <- Jason.decode(payload) do
      {:ok, event}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_signature}
      {:ok, _} -> {:error, :invalid_signature}
      _ -> {:error, :invalid_signature}
    end
  end

  defp parse_timestamp(t) when is_binary(t) do
    case Integer.parse(t) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp parse_timestamp(_), do: {:error, :invalid_timestamp}

  defp check_tolerance(timestamp) do
    now = System.system_time(:second)

    if abs(now - timestamp) <= @signature_tolerance_sec do
      :ok
    else
      {:error, :timestamp_expired}
    end
  end

  defp hmac(secret, message) do
    :hmac
    |> :crypto.mac(:sha256, secret, message)
    |> Base.encode16(case: :lower)
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  defp secure_compare(_, _), do: false

  defp first_item_id(sub) do
    sub
    |> get_in(["items", "data"])
    |> List.wrap()
    |> List.first()
    |> case do
      %{"id" => id} -> id
      _ -> nil
    end
  end

  defp request(method, path, form \\ %{}) do
    opts = [
      method: method,
      url: @api_base <> path,
      auth: {:bearer, config()[:secret_key]},
      receive_timeout: 30_000
    ]

    opts =
      if method == :get or form == %{} do
        opts
      else
        Keyword.put(opts, :form, stringify(form))
      end

    case Req.request(opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("stripe_http_error status=#{status} body=#{inspect(body)}")
        {:error, stripe_error(body)}

      {:error, reason} ->
        Logger.warning("stripe_unreachable #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp stripe_error(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp stripe_error(%{"error" => %{"code" => code}}), do: code
  defp stripe_error(_), do: :stripe_error

  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_binary(v), do: v
  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v), do: to_string(v)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp config, do: Application.get_env(:mokaid, :stripe, [])
end
