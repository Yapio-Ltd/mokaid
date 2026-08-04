defmodule MokaidWeb.Plugs.RequirePlatformAdmin do
  @moduledoc """
  Ensures the authenticated user is a platform operator (`is_platform_admin`).
  Must run after `Authenticate`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{is_platform_admin: true} ->
        conn

      %{} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "forbidden", message: "Platform admin access required"}})
        |> halt()

      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: %{code: "unauthorized", message: "Invalid or missing token"}})
        |> halt()
    end
  end
end
