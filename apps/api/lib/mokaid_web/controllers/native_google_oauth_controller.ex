defmodule MokaidWeb.NativeGoogleOAuthController do
  @moduledoc "Member-bound Google integration authorization for the desktop client."
  use MokaidWeb, :controller

  alias Mokaid.Integrations.MailOAuthFlow

  def start(conn, params) do
    with {:ok, result} <-
           MailOAuthFlow.start(workspace_id(conn), current_member(conn), params["provider_key"]) do
      json(conn, %{data: result})
    else
      {:error, :oauth_not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{
            code: "oauth_not_configured",
            message:
              "Google connection is temporarily unavailable. Contact your workspace administrator."
          }
        })

      other ->
        other
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, result} <-
           MailOAuthFlow.get(workspace_id(conn), current_member(conn).id, id, details: true) do
      json(conn, %{data: result})
    end
  end

  def cancel(conn, %{"id" => id}) do
    with {:ok, result} <-
           MailOAuthFlow.cancel(workspace_id(conn), current_member(conn).id, id, details: true) do
      json(conn, %{data: result})
    end
  end
end
