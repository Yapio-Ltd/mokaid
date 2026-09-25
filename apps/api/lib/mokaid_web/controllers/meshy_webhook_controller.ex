defmodule MokaidWeb.MeshyWebhookController do
  @moduledoc """
  Meshy webhook notifications are untrusted hints, as recommended by Meshy's
  webhook guide. Only known task IDs can enqueue an authoritative authenticated
  API fetch. No model URL, status or progress in a webhook is trusted.

  Meshy's public documentation does not specify its signing scheme. The secret
  is reserved in runtime config for activation once a real signed delivery is
  available; accepting a made-up HMAC scheme would silently break notifications.
  """
  use MokaidWeb, :controller

  def notify(conn, params) do
    body = conn.assigns[:raw_body] || ""

    if byte_size(body) <= 1_000_000 do
      case Mokaid.Avatars.webhook_hint(params, body) do
        {:ok, _} -> conn |> put_status(:accepted) |> json(%{ok: true})
        {:error, _} -> conn |> put_status(:service_unavailable) |> json(%{ok: false})
      end
    else
      conn |> put_status(:request_entity_too_large) |> json(%{ok: false})
    end
  end
end
