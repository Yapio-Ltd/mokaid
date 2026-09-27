defmodule MokaidWeb.MailOAuthController do
  use MokaidWeb, :controller
  alias Mokaid.Integrations.MailOAuthFlow

  def google_start(conn, _params) do
    with {:ok, result} <- MailOAuthFlow.start(workspace_id(conn), current_member(conn)) do
      json(conn, %{data: result})
    else
      {:error, :oauth_not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{
            code: "oauth_not_configured",
            message:
              "Google connection is temporarily unavailable. Try IMAP or contact your administrator."
          }
        })

      other ->
        other
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, result} <- MailOAuthFlow.get(workspace_id(conn), current_member(conn).id, id) do
      json(conn, %{data: result})
    end
  end

  def cancel(conn, %{"id" => id}) do
    with {:ok, result} <- MailOAuthFlow.cancel(workspace_id(conn), current_member(conn).id, id) do
      json(conn, %{data: result})
    end
  end

  def google_callback(conn, params) do
    {status, title, message} =
      case MailOAuthFlow.complete(params, details: true) do
        {:ok, %{provider_key: "gmail"}} ->
          {200, "Gmail connected",
           "Your mailbox is connected and its first synchronization has started. Return to Mokaid Desktop; you can close this tab."}

        {:ok, %{provider_key: provider}} ->
          {200, "#{provider_name(provider)} connected",
           "Authorization is complete. Return to Mokaid Desktop; you can close this tab."}

        {:error, "authorization_cancelled"} ->
          {400, "Google access was not granted",
           "Google refused access or sign-in was cancelled. If Google showed an app-testing restriction, select an allowed Google account or contact your workspace administrator. Return to Mokaid Desktop to try again."}

        {:error, "integration_permission_required"} ->
          {400, "Google permission required",
           "Return to Mokaid Desktop, connect the service again, and allow the permissions requested for that service."}

        {:error, "mail_permission_required"} ->
          {400, "Gmail permission required",
           "Return to Mokaid Desktop, connect Gmail again, and allow access to your mail."}

        {:error, _} ->
          {400, "Connection could not be completed",
           "Return to Mokaid Desktop and try connecting again. The app will show the connection status."}
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'"
    )
    |> put_status(status)
    |> html("""
    <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{title} · Mokaid</title><style>body{margin:0;background:#0b0c17;color:#f2efff;font:16px system-ui;display:grid;min-height:100vh;place-items:center}main{max-width:440px;margin:24px;padding:36px;border:1px solid #39314f;border-radius:24px}h1{font-size:26px}p{color:#c2bad7;line-height:1.6}</style>
    <main><p>Mokaid</p><h1>#{title}</h1><p>#{message}</p></main></html>
    """)
  end

  defp provider_name("google_drive"), do: "Google Drive"
  defp provider_name("google_calendar"), do: "Google Calendar"
  defp provider_name("google_docs"), do: "Google Docs"
  defp provider_name("google_sheets"), do: "Google Sheets"
  defp provider_name("google_meet"), do: "Google Meet"
  defp provider_name(_), do: "Google"
end
