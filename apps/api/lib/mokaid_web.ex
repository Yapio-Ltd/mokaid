defmodule MokaidWeb do
  @moduledoc "Web layer entry points: controllers, channels, JSON views."

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]

      import Plug.Conn

      alias Mokaid.Permissions

      action_fallback MokaidWeb.FallbackController

      defp workspace_id(conn), do: conn.assigns.current_workspace_id
      defp current_member(conn), do: conn.assigns.current_member
      defp current_user(conn), do: conn.assigns.current_user
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
