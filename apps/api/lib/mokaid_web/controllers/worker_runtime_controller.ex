defmodule MokaidWeb.WorkerRuntimeController do
  use MokaidWeb, :controller
  alias Mokaid.AI.ManagedRuntime

  def file(
        conn,
        %{"workspace_id" => workspace_id, "run_id" => run_id, "file_id" => file_id} = params
      ) do
    with {:ok, _} <- Ecto.UUID.cast(file_id),
         {:ok, _} <-
           ManagedRuntime.authorize(
             workspace_id,
             run_id,
             Map.put(params, "tool_name", "read_file")
           ),
         {:ok, data} <- ManagedRuntime.file(workspace_id, run_id, file_id) do
      json(conn, %{data: data})
    else
      :error -> runtime_error(conn, :not_found)
      {:error, reason} -> runtime_error(conn, reason)
    end
  end

  def file(conn, _params), do: runtime_error(conn, :invalid_request)

  for {action, function} <- [
        authorize: :authorize,
        reserve: :reserve,
        settle: :settle,
        participants: :reserve_participant,
        release_participant: :release_participant
      ] do
    def unquote(action)(conn, %{"workspace_id" => workspace_id, "run_id" => run_id} = params) do
      case ManagedRuntime.unquote(function)(workspace_id, run_id, params) do
        {:ok, data} -> json(conn, %{data: data})
        {:error, reason} -> runtime_error(conn, reason)
      end
    end

    def unquote(action)(conn, _params), do: runtime_error(conn, :invalid_request)
  end

  defp runtime_error(conn, reason) do
    status =
      case reason do
        :not_found ->
          :not_found

        reason
        when reason in [
               :runtime_capacity,
               :agent_busy,
               :participant_released,
               :reservation_closed,
               :lease_expired
             ] ->
          :conflict

        :insufficient_credits ->
          :payment_required

        reason
        when reason in [
               :invalid_request,
               :invalid_usage,
               :invalid_participant,
               :invalid_complexity
             ] ->
          :unprocessable_entity

        _ ->
          :forbidden
      end

    conn
    |> put_status(status)
    |> json(%{
      error: %{code: to_string(reason), message: "This execution is not currently authorized."},
      data: %{allowed: false, reason: to_string(reason)}
    })
  end
end
