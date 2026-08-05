defmodule MokaidWeb.TranzilaWebhookTest do
  use MokaidWeb.ConnCase, async: true

  alias Mokaid.Billing

  setup do
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

  defp approved_notify(invoice) do
    %{
      "Response" => "000",
      "invoice_id" => invoice.id,
      "sum" => "49.00",
      "currency" => "2",
      "TranzilaTK" => "tk_test_123",
      "expmonth" => "07",
      "expyear" => "30",
      "ccno" => "1234",
      "cardtype" => "2",
      "index" => "555"
    }
  end

  test "approved notify settles the invoice, activates the plan and stores the token",
       %{conn: conn, workspace: workspace, invoice: invoice} do
    conn = post(conn, "/api/tranzila/notify", approved_notify(invoice))
    assert json_response(conn, 200) == %{"ok" => true}

    invoice = Billing.get_invoice_by_id(invoice.id)
    assert invoice.status == "paid"
    assert invoice.external_payment_id == "555"

    subscription = Billing.get_subscription(workspace.id)
    assert subscription.plan.key == "starter"
    assert subscription.external_customer_id == "tk_test_123"
    assert subscription.payment_method["last4"] == "1234"
    assert subscription.payment_method["expire_month"] == "07"
    assert subscription.payment_method["expire_year"] == "30"
  end

  test "replayed notify is idempotent", %{conn: conn, invoice: invoice} do
    post(conn, "/api/tranzila/notify", approved_notify(invoice))
    conn = post(build_conn(), "/api/tranzila/notify", approved_notify(invoice))

    assert json_response(conn, 200) == %{"ok" => true}
    assert Billing.get_invoice_by_id(invoice.id).status == "paid"
  end

  test "amount mismatch is rejected and the invoice stays pending",
       %{conn: conn, workspace: workspace, invoice: invoice} do
    params = Map.put(approved_notify(invoice), "sum", "1.00")
    conn = post(conn, "/api/tranzila/notify", params)

    assert json_response(conn, 200) == %{"ok" => true}
    assert Billing.get_invoice_by_id(invoice.id).status == "pending"
    assert Billing.get_subscription(workspace.id) == nil
  end

  test "declined transaction is ignored", %{conn: conn, invoice: invoice} do
    params = Map.put(approved_notify(invoice), "Response", "004")
    conn = post(conn, "/api/tranzila/notify", params)

    assert json_response(conn, 200) == %{"ok" => true}
    assert Billing.get_invoice_by_id(invoice.id).status == "pending"
  end

  test "unknown or malformed invoice ids are ignored", %{conn: conn, invoice: invoice} do
    conn1 =
      post(conn, "/api/tranzila/notify", %{
        "Response" => "000",
        "invoice_id" => Ecto.UUID.generate()
      })

    assert json_response(conn1, 200) == %{"ok" => true}

    conn2 =
      post(build_conn(), "/api/tranzila/notify", %{
        "Response" => "000",
        "invoice_id" => "not-a-uuid"
      })

    assert json_response(conn2, 200) == %{"ok" => true}
    assert Billing.get_invoice_by_id(invoice.id).status == "pending"
  end
end
