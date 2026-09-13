defmodule MokaidWeb.DesktopAuthController do
  use MokaidWeb, :controller
  alias Mokaid.Auth.Desktop
  alias MokaidWeb.JSON, as: Serializer

  plug :protect_response
  plug :rate_limit

  def create(conn, params) do
    with {:ok, request} <- Desktop.create_request(params) do
      conn
      |> put_status(:created)
      |> json(%{
        data: %{
          request_id: request.id,
          authorization_url: Desktop.authorization_url(request),
          expires_in: 300
        }
      })
    else
      _ -> error(conn, :bad_request, "invalid_request")
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, request} <- Desktop.get_request(id) do
      json(conn, %{
        data: %{
          request_id: request.id,
          application: "Mokaid Desktop",
          redirect_uri: request.redirect_uri,
          expires_at: request.expires_at,
          user: Serializer.user(current_user(conn))
        }
      })
    else
      _ -> error(conn, :bad_request, "invalid_request")
    end
  end

  def approve(conn, %{"id" => id}) do
    with {:ok, url} <- Desktop.approve(id, current_user(conn)) do
      json(conn, %{data: %{redirect_url: url}})
    else
      _ -> error(conn, :bad_request, "invalid_request")
    end
  end

  def token(conn, %{"grant_type" => "authorization_code"} = params),
    do: token_response(conn, Desktop.exchange(params))

  def token(conn, %{"grant_type" => "refresh_token", "refresh_token" => token}),
    do: token_response(conn, Desktop.refresh(token))

  def token(conn, _params), do: error(conn, :bad_request, "invalid_grant")

  def revoke(conn, params) do
    Desktop.revoke(params["refresh_token"])
    send_resp(conn, :no_content, "")
  end

  defp token_response(conn, {:ok, tokens}) do
    json(conn, %{data: %{tokens | user: Serializer.user(tokens.user)}})
  end

  defp token_response(conn, _), do: error(conn, :bad_request, "invalid_grant")

  defp protect_response(conn, _) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp rate_limit(conn, _) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    action = action_name(conn)
    limit = if action in [:token, :revoke], do: 60, else: 15

    case Hammer.check_rate("desktop-auth:#{action}:#{ip}", 60_000, limit) do
      {:allow, _} ->
        conn

      {:deny, _} ->
        conn
        |> put_resp_header("retry-after", "60")
        |> error(:too_many_requests, "rate_limited")
        |> halt()

      _ ->
        conn |> error(:service_unavailable, "temporarily_unavailable") |> halt()
    end
  end

  defp error(conn, status, code) do
    conn
    |> put_status(status)
    |> json(%{
      error: %{
        code: code,
        message: "Desktop authorization could not be completed. Start again from Mokaid Desktop."
      }
    })
  end
end
