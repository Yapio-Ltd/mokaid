defmodule MokaidWeb.WorkerMailToolsController do
  use MokaidWeb, :controller
  alias Mokaid.Mail.{AgentAccess, AgentTools}

  def call_tool(
        conn,
        %{"access_token" => token, "action" => action, "arguments" => args} = params
      )
      when is_binary(token) and byte_size(token) <= 16_384 and is_map(args) and
             action in ~w(list search read save_attachment) do
    actor = params["acting_agent_id"]

    with {:ok, context} <- AgentAccess.authorize(token, action, actor),
         context <-
           Map.merge(context, %{
             access_token: token,
             acting_agent_id: actor,
             reauthorize: fn -> AgentAccess.authorize(token, action, actor) end
           }),
         {:ok, data} <- AgentTools.call(context, action, args),
         {:ok, _} <- AgentAccess.authorize(token, action, actor) do
      conn |> put_resp_header("cache-control", "private, no-store") |> json(%{data: data})
    else
      {:error, reason} -> error(conn, reason)
      _ -> error(conn, :mail_access_denied)
    end
  end

  def call_tool(conn, _), do: error(conn, :invalid_mail_tool_request)

  def refresh_access(conn, %{"access_token" => token, "action" => action} = params)
      when is_binary(token) and byte_size(token) <= 16_384 and
             action in ~w(list search read save_attachment) do
    case AgentAccess.refresh(token, action, params["acting_agent_id"]) do
      {:ok, data} ->
        conn |> put_resp_header("cache-control", "private, no-store") |> json(%{data: data})

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def refresh_access(conn, _), do: error(conn, :invalid_mail_tool_request)

  defp error(conn, reason) do
    {status, code} =
      case reason do
        reason
        when reason in [:invalid_mail_tool_request, :invalid_mail_folder, :mail_account_ambiguous] ->
          {422, reason}

        reason when reason in [:mail_message_not_found, :mail_account_not_found, :not_found] ->
          {404, :mail_not_found}

        reason when reason in [:attachment_too_large] ->
          {413, reason}

        reason
        when reason in [
               :mail_details_unavailable,
               :mail_attachment_unavailable,
               :mail_provider_unavailable,
               :mail_worker_unavailable,
               :mail_file_storage_unavailable
             ] ->
          {502, :mail_temporarily_unavailable}

        :mail_reconnect_required ->
          {409, :mail_reconnect_required}

        :mail_file_permission_denied ->
          {403, :mail_file_permission_denied}

        _ ->
          {403, :mail_access_denied}
      end

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_status(status)
    |> json(%{
      error: %{code: to_string(code), message: "The mailbox operation could not be completed."}
    })
  end
end
