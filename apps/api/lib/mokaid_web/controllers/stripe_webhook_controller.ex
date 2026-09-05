defmodule MokaidWeb.StripeWebhookController do
  @moduledoc """
  Public Stripe webhook endpoint.

  Signature is verified with `STRIPE_WEBHOOK_SECRET`. Until that secret is
  configured the endpoint answers 503 so Stripe retries after you paste it.
  Valid signatures that fail business checks still return 200 to avoid
  infinite retries.
  """

  use MokaidWeb, :controller

  require Logger

  alias Mokaid.Billing
  alias Mokaid.Billing.Stripe

  def notify(conn, _params) do
    raw = conn.assigns[:raw_body] || ""
    signature = conn |> get_req_header("stripe-signature") |> List.first()

    case Stripe.verify_webhook(raw, signature) do
      {:ok, event} ->
        handle_event(event)
        json(conn, %{ok: true})

      {:error, :webhook_secret_missing} ->
        Logger.warning("stripe_webhook_secret_missing")

        conn
        |> put_status(:service_unavailable)
        |> json(%{error: %{code: "webhook_not_configured"}})

      {:error, reason} ->
        Logger.warning("stripe_webhook_rejected reason=#{reason}")

        conn
        |> put_status(:bad_request)
        |> json(%{error: %{code: "invalid_signature"}})
    end
  end

  defp handle_event(%{"type" => type, "data" => %{"object" => object}}) do
    Logger.info("stripe_webhook type=#{type} id=#{object["id"]}")

    case type do
      "checkout.session.completed" -> handle_checkout(object)
      "invoice.paid" -> handle_invoice_paid(object)
      "invoice.payment_failed" -> handle_invoice_failed(object)
      "customer.subscription.updated" -> handle_subscription_updated(object)
      "customer.subscription.deleted" -> handle_subscription_deleted(object)
      _ -> :ok
    end
  end

  defp handle_event(_), do: :ok

  defp handle_checkout(session) do
    if session["payment_status"] in ["paid", "no_payment_required"] do
      invoice_id = session["metadata"]["invoice_id"] || session["client_reference_id"]

      with {:ok, _} <- Ecto.UUID.cast(invoice_id),
           %{} = invoice <- Billing.get_invoice_by_id(invoice_id) do
        reference = Stripe.stripe_id(session["payment_intent"]) || session["id"]
        Billing.attach_payment_reference(invoice, reference)

        Billing.mark_invoice_paid(invoice, %{
          buyer_key: Stripe.stripe_id(session["customer"]),
          subscription_id: Stripe.stripe_id(session["subscription"]),
          card: %{}
        })
      else
        _ ->
          Logger.warning("stripe_checkout_unknown_invoice session=#{session["id"]}")
          {:ignored, :unknown_invoice}
      end
    else
      {:ignored, :unpaid}
    end
  end

  defp handle_invoice_paid(stripe_invoice) do
    reason = stripe_invoice["billing_reason"]

    # First invoice is settled by checkout.session.completed.
    if reason in ["subscription_cycle", "subscription_update"] do
      Billing.apply_stripe_renewal(stripe_invoice)
    else
      :ok
    end
  end

  defp handle_invoice_failed(stripe_invoice) do
    sub_id = Stripe.stripe_id(stripe_invoice["subscription"])

    case Billing.get_subscription_by_external_subscription_id(sub_id) do
      nil ->
        {:ignored, :unknown_subscription}

      subscription ->
        Billing.mark_renewal_failed(subscription, :stripe_payment_failed)
    end
  end

  defp handle_subscription_updated(object) do
    Billing.sync_stripe_subscription(object)
  end

  defp handle_subscription_deleted(object) do
    Billing.cancel_stripe_subscription(object)
  end
end
