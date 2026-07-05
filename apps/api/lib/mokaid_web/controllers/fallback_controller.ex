defmodule MokaidWeb.FallbackController do
  use Phoenix.Controller, formats: [:json]

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          # Cast errors carry non-string values like `type: {:array, :map}`.
          String.replace(acc, "%{#{key}}", stringify(value))
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "validation_error", message: "Validation failed", details: errors}})
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{code: "forbidden", message: "You do not have permission for this action"}})
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Resource not found"}})
  end

  def call(conn, {:error, :invalid_credentials}) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{code: "invalid_credentials", message: "Invalid email or password"}})
  end

  def call(conn, {:error, reason}) when is_atom(reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: to_string(reason), message: humanize(reason)}})
  end

  def call(conn, nil) do
    call(conn, {:error, :not_found})
  end

  defp humanize(reason) do
    reason |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp stringify(value) do
    to_string(value)
  rescue
    Protocol.UndefinedError -> inspect(value)
  end
end
