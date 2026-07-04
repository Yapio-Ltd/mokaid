defmodule MokaidWeb.NotificationChannel do
  use MokaidWeb, :channel

  @impl true
  def join("notifications:" <> user_id, _params, socket) do
    if socket.assigns.current_user.id == user_id do
      {:ok, socket}
    else
      {:error, %{reason: "forbidden"}}
    end
  end
end
