defmodule Mokaid.Billing.StripeTest do
  use ExUnit.Case, async: false

  alias Mokaid.Billing.Stripe

  @config [
    secret_key: "sk_test_xxx",
    publishable_key: "pk_test_xxx",
    webhook_secret: "whsec_test_secret",
    currency: "usd",
    web_base_url: "https://app.example.com"
  ]

  setup do
    previous = Application.get_env(:mokaid, :stripe)
    Application.put_env(:mokaid, :stripe, @config)
    on_exit(fn -> Application.put_env(:mokaid, :stripe, previous) end)
    :ok
  end

  describe "enabled?/0" do
    test "true with a secret key, false when missing" do
      assert Stripe.enabled?()

      Application.put_env(:mokaid, :stripe, Keyword.put(@config, :secret_key, ""))
      refute Stripe.enabled?()

      Application.put_env(:mokaid, :stripe, Keyword.delete(@config, :secret_key))
      refute Stripe.enabled?()
    end
  end

  describe "checkout_form/1" do
    test "subscription session includes recurring price_data and metadata" do
      form =
        Stripe.checkout_form(%{
          kind: "subscription",
          amount_cents: 4_900,
          description: "Mokaid Starter plan (monthly)",
          invoice_id: "inv-1",
          workspace_id: "ws-1",
          customer_id: "cus_123",
          plan_key: "starter",
          billing_cycle: "monthly",
          return_path: "/billing"
        })

      assert form["mode"] == "subscription"
      assert form["customer"] == "cus_123"
      assert form["client_reference_id"] == "inv-1"
      assert form["line_items[0][price_data][unit_amount]"] == 4_900
      assert form["line_items[0][price_data][recurring][interval]"] == "month"
      assert form["subscription_data[metadata][plan_key]"] == "starter"
      assert form["success_url"] == "https://app.example.com/billing?checkout=success"
      assert form["cancel_url"] == "https://app.example.com/billing?checkout=canceled"
      refute Map.has_key?(form, "customer_email")
    end

    test "payment session sets setup_future_usage and rejects protocol-relative return paths" do
      form =
        Stripe.checkout_form(%{
          kind: "credits",
          amount_cents: 1_900,
          description: "1000 AI credits",
          invoice_id: "inv-2",
          workspace_id: "ws-1",
          buyer_email: "user@example.com",
          return_path: "//evil.example/phish"
        })

      assert form["mode"] == "payment"
      assert form["payment_intent_data[setup_future_usage]"] == "off_session"
      assert form["customer_email"] == "user@example.com"
      assert form["success_url"] == "https://app.example.com/billing?checkout=success"
    end
  end

  describe "verify_webhook/2" do
    test "accepts a valid signature and rejects a tampered one" do
      payload = ~s({"id":"evt_1","type":"checkout.session.completed","data":{"object":{}}})
      sig = sign(payload, "whsec_test_secret")

      assert {:ok, %{"id" => "evt_1"}} = Stripe.verify_webhook(payload, sig)
      assert {:error, :invalid_signature} = Stripe.verify_webhook(payload <> "x", sig)
      assert {:error, :missing_signature} = Stripe.verify_webhook(payload, nil)
    end

    test "refuses events when the webhook secret is not configured" do
      Application.put_env(:mokaid, :stripe, Keyword.put(@config, :webhook_secret, "CHANGE_ME"))
      assert {:error, :webhook_secret_missing} = Stripe.verify_webhook("{}", "t=1,v1=abc")
    end
  end

  describe "id helpers" do
    test "stripe_id unwraps expanded objects" do
      assert Stripe.stripe_id("cus_1") == "cus_1"
      assert Stripe.stripe_id(%{"id" => "sub_1"}) == "sub_1"
      assert Stripe.stripe_id(nil) == nil
      assert Stripe.stripe_customer?("cus_abc")
      refute Stripe.stripe_customer?("tk_tranzila")
      assert Stripe.stripe_subscription?("sub_abc")
      refute Stripe.stripe_subscription?(nil)
    end
  end

  defp sign(payload, secret) do
    timestamp = System.system_time(:second)

    mac =
      :hmac
      |> :crypto.mac(:sha256, secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{mac}"
  end
end
