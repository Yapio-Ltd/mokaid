defmodule Mokaid.Billing.TranzilaTest do
  # Not async: checkout_url/enabled? read global application config.
  use ExUnit.Case, async: false

  alias Mokaid.Billing.Tranzila

  @config [
    app_key: "pubkey",
    secret: "privkey",
    terminal: "fxpyapio",
    token_terminal: "fxpyapiotok",
    currency: "USD",
    api_base_url: "https://api.example.com",
    web_base_url: "https://app.example.com"
  ]

  setup do
    previous = Application.get_env(:mokaid, :tranzila)
    Application.put_env(:mokaid, :tranzila, @config)
    on_exit(fn -> Application.put_env(:mokaid, :tranzila, previous) end)
    :ok
  end

  describe "auth_headers/1" do
    test "matches the documented HMAC construction (independent openssl vector)" do
      # openssl: HMAC-SHA256(key = secret <> time <> nonce, msg = app_key)
      headers =
        Tranzila.auth_headers(
          app_key: "pubkey",
          secret: "privkey",
          time: 1_700_000_000,
          nonce: "abc123"
        )

      assert {"X-tranzila-api-app-key", "pubkey"} in headers
      assert {"X-tranzila-api-request-time", "1700000000"} in headers
      assert {"X-tranzila-api-nonce", "abc123"} in headers

      assert {"X-tranzila-api-access-token",
              "ecb0716079f4ca0eaeb200b15193561328b5d6b67b0af030e279276e472f223f"} in headers
    end

    test "generates an 80-char hex nonce by default" do
      headers = Map.new(Tranzila.auth_headers())
      nonce = headers["X-tranzila-api-nonce"]

      assert String.length(nonce) == 80
      assert nonce =~ ~r/^[0-9a-f]+$/
    end
  end

  describe "checkout_url/1" do
    test "one-time sale uses the standard terminal with tranmode=A" do
      url =
        Tranzila.checkout_url(%{
          mode: :one_time,
          amount_cents: 7_900,
          description: "5000 AI credits",
          invoice_id: "0b5f8c6e-0000-0000-0000-000000000000"
        })

      assert url =~ "https://direct.tranzila.com/fxpyapio/iframenew.php?"

      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["sum"] == "79.00"
      assert params["currency"] == "2"
      assert params["tranmode"] == "A"
      assert params["invoice_id"] == "0b5f8c6e-0000-0000-0000-000000000000"
      assert params["notify_url_address"] == "https://api.example.com/api/tranzila/notify"
      assert params["success_url_address"] == "https://app.example.com/billing?payment=done"
      assert params["fail_url_address"] == "https://app.example.com/billing?payment=failed"
    end

    test "subscription sale uses the token terminal with tranmode=AK" do
      url =
        Tranzila.checkout_url(%{
          mode: :tokenize,
          amount_cents: 4_901,
          description: "Starter plan",
          invoice_id: "inv",
          return_path: "/onboarding?step=4",
          buyer_email: "user@example.com"
        })

      assert url =~ "https://direct.tranzila.com/fxpyapiotok/iframenew.php?"

      params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert params["tranmode"] == "AK"
      assert params["sum"] == "49.01"
      assert params["email"] == "user@example.com"
      assert params["success_url_address"] == "https://app.example.com/onboarding?step=4"
    end
  end

  describe "amounts" do
    test "format_amount renders minor units as decimal strings" do
      assert Tranzila.format_amount(0) == "0.00"
      assert Tranzila.format_amount(5) == "0.05"
      assert Tranzila.format_amount(4_900) == "49.00"
      assert Tranzila.format_amount(149_000) == "1490.00"
    end

    test "parse_amount_cents inverts hosted-page decimal amounts" do
      assert Tranzila.parse_amount_cents("49.00") == 4_900
      assert Tranzila.parse_amount_cents("49") == 4_900
      assert Tranzila.parse_amount_cents("0.05") == 5
      assert Tranzila.parse_amount_cents(49) == 4_900
      assert Tranzila.parse_amount_cents(49.0) == 4_900
      assert Tranzila.parse_amount_cents("not a number") == nil
      assert Tranzila.parse_amount_cents(nil) == nil
    end
  end

  describe "enabled?/0" do
    test "true with full config, false when any key is missing" do
      assert Tranzila.enabled?()

      Application.put_env(:mokaid, :tranzila, Keyword.put(@config, :secret, ""))
      refute Tranzila.enabled?()

      Application.put_env(:mokaid, :tranzila, Keyword.delete(@config, :app_key))
      refute Tranzila.enabled?()
    end
  end

  describe "transaction_approved?/1" do
    test "only Response 000 is approved" do
      assert Tranzila.transaction_approved?(%{"Response" => "000"})
      refute Tranzila.transaction_approved?(%{"Response" => "001"})
      refute Tranzila.transaction_approved?(%{"Response" => "004"})
      refute Tranzila.transaction_approved?(%{})
    end
  end

  describe "charge_token/1" do
    test "refuses to charge without the stored card expiry" do
      assert {:error, :missing_card_expiry} =
               Tranzila.charge_token(%{
                 token: "tk",
                 amount_cents: 4_900,
                 description: "renewal"
               })

      assert {:error, :missing_card_expiry} =
               Tranzila.charge_token(%{
                 token: "tk",
                 expire_month: "13",
                 expire_year: "2030",
                 amount_cents: 4_900,
                 description: "renewal"
               })
    end
  end
end
