defmodule MokaidWeb.RuntimeBudgetController do
  use MokaidWeb, :controller

  def create(conn, %{"id" => task_id} = params) do
    case Mokaid.AI.ManagedRuntime.extend_budget(
           workspace_id(conn),
           task_id,
           current_member(conn),
           params
         ) do
      {:ok, data} ->
        json(conn, %{data: data})

      {:error, :forbidden} ->
        {:error, :forbidden}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} when is_atom(reason) ->
        status = if reason == :insufficient_credits, do: :payment_required, else: :conflict

        conn
        |> put_status(status)
        |> json(%{
          error: %{
            code: to_string(reason),
            message: "The additional task credits could not be reserved."
          }
        })

      _ ->
        {:error, :unprocessable_entity}
    end
  end
end
