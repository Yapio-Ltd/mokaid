defmodule MokaidWeb.MailSendController do
  use MokaidWeb, :controller
  alias Mokaid.Mail.Composer

  def send(conn, params) do
    with :ok <- Permissions.authorize(current_member(conn), "mail.send"),
         {:allow, _} <- Hammer.check_rate("mail-send:#{current_member(conn).id}", 60_000, 20),
         {:ok, data} <- Composer.send(workspace_id(conn), current_member(conn), params) do
      json(conn, %{data: data})
    else
      {:deny, _} ->
        error(conn, 429, "rate_limited", "Wait one minute before sending more messages.")

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def status(conn, %{"id" => id}) do
    case Composer.status(workspace_id(conn), current_member(conn), id) do
      {:ok, data} -> json(conn, %{data: data})
      {:error, reason} -> error_response(conn, reason)
    end
  end

  defp error_response(conn, :forbidden),
    do: error(conn, 403, "forbidden", "You do not have permission to send mail.")

  defp error_response(conn, :not_found),
    do: error(conn, 404, "not_found", "Mail account or send request is unavailable.")

  defp error_response(conn, :idempotency_conflict),
    do:
      error(
        conn,
        409,
        "idempotency_conflict",
        "This send request was already used for a different message."
      )

  defp error_response(conn, _),
    do:
      error(
        conn,
        422,
        "invalid_message",
        "Check recipients, message size, reply account and attachment limits."
      )

  defp error(conn, status, code, message),
    do: conn |> put_status(status) |> json(%{error: %{code: code, message: message}})
end
