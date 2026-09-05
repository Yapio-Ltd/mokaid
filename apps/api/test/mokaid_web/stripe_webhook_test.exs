defmodule MokaidWeb.StripeWebhookTest do
  use MokaidWeb.ConnCase, async: false

  alias Mokaid.Billing

  @secret "whsec_test_secret"

  setup do
    previous = Application.get_env(:mokaid, :stripe)

    Application.put_env(:mokaid, :stripe,
      secret_key: "sk_test_xxx",
      publishable_key: "pk_test_xxx",
      webhook_secret: @secret,
      currency: "usd",
      web_base_url: "https://app.example.com"
    )

    on_exit(fn -> Application.put_env(:mokaid, :stripe, previous) end)

    Billing.seed_plans()
    {workspace, _owner} = workspace_fixture()

    {:ok, invoice} =
      Billing.create_pending_invoice(workspace.id, %{
        "kind" => "subscription",
        "amount_cents" => 4_900,
        "line_items" => [
          %{
            "description" => "Starter plan — monthly",
            "amount_cents" => 4_900,
            "plan_key" => "starter",
            "billing_cycle" => "monthly"
          }
        ]
      })

    %{workspace: workspace, invoice: invoice}
  end

  test "checkout.session.completed settles the invoice and activates the plan",
       %{conn: conn, workspace: workspace, invoice: invoice} do
    conn = post_event(conn, checkout_event(invoice))
    assert json_response(conn, 200) == %{"ok" => true}

    invoice = Billing.get_invoice_by_id(invoice.id)
    assert invoice.status == "paid"
    assert invoice.external_payment_id == "pi_test_1"

    subscription = Billing.get_subscription(workspace.id)
    assert subscription.plan.key == "starter"
    assert subscription.external_customer_id == "cus_test_1"
    assert subscription.external_subscription_id == "sub_test_1"
  end

  test "replayed checkout event is idempotent", %{conn: conn, invoice: invoice} do
    event = checkout_event(invoice)
    post_event(conn, event)
    conn = post_event(build_conn(), event)

    assert json_response(conn, 200) == %{"ok" => true}
    assert Billing.get_invoice_by_id(invoice.id).status == "paid"
    assert length(Billing.list_invoices(invoice.workspace_id)) == 1
  end

  test "invalid signature is rejected and the invoice stays pending",
       %{conn: conn, invoice: invoice} do
    payload = Jason.encode!(checkout_event(invoice))

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("stripe-signature", "t=1,v1=deadbeef")
      |> post("/api/stripe/webhook", payload)

    assert json_response(conn, 400)["error"]["code"] == "invalid_signature"
    assert Billing.get_invoice_by_id(invoice.id).status == "pending"
  end

  test "missing webhook secret answers 503", %{invoice: invoice} do
    Application.put_env(:mokaid, :stripe,
      secret_key: "sk_test_xxx",
      webhook_secret: "CHANGE_ME"
    )

    conn = post_event(build_conn(), checkout_event(invoice))
    assert json_response(conn, 503)["error"]["code"] == "webhook_not_configured"
    assert Billing.get_invoice_by_id(invoice.id).status == "pending"
  end

  test "invoice.paid renewal is idempotent on the Stripe invoice id", %{workspace: workspace} do
    {:ok, subscription} = Billing.change_plan(workspace.id, "starter", "monthly")

    subscription
    |> Ecto.Changeset.change(external_subscription_id: "sub_renew")
    |> Mokaid.Repo.update!()

    stripe_invoice = %{
      "id" => "in_renew_1",
      "billing_reason" => "subscription_cycle",
      "subscription" => "sub_renew",
      "amount_paid" => 4_900
    }

    assert {:ok, _} = Billing.apply_stripe_renewal(stripe_invoice)
    assert {:ok, :already_recorded} = Billing.apply_stripe_renewal(stripe_invoice)

    invoices =
      workspace.id
      |> Billing.list_invoices()
      |> Enum.filter(&(&1.external_payment_id == "in_renew_1"))

    assert length(invoices) == 1
    assert hd(invoices).status == "paid"
  end

  defp checkout_event(invoice) do
    %{
      "id" => "evt_test_1",
      "type" => "checkout.session.completed",
      "data" => %{
        "object" => %{
          "id" => "cs_test_1",
          "payment_status" => "paid",
          "payment_intent" => "pi_test_1",
          "customer" => "cus_test_1",
          "subscription" => "sub_test_1",
          "client_reference_id" => invoice.id,
          "metadata" => %{"invoice_id" => invoice.id}
        }
      }
    }
  end

  defp post_event(conn, event) do
    payload = Jason.encode!(event)
    timestamp = System.system_time(:second)

    mac =
      :hmac
      |> :crypto.mac(:sha256, @secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{timestamp},v1=#{mac}")
    |> post("/api/stripe/webhook", payload)
  end
end
