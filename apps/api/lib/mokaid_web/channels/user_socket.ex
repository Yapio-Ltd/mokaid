defmodule MokaidWeb.UserSocket do
  use Phoenix.Socket

  channel "workspace:*", MokaidWeb.WorkspaceChannel
  channel "task:*", MokaidWeb.TaskChannel
  channel "agent:*", MokaidWeb.AgentChannel
  channel "notifications:*", MokaidWeb.NotificationChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case resolve_user(token) do
      {:ok, user} -> {:ok, assign(socket, :current_user, user)}
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  defp resolve_user(token) do
    case Application.fetch_env!(:mokaid, :auth)[:mode] do
      :cognito ->
        with {:ok, claims} <- Mokaid.Auth.Cognito.verify_token(token) do
          Mokaid.Accounts.upsert_from_cognito(claims)
        end

      :dev_fallback ->
        with {:ok, user_id} <- Mokaid.Auth.Token.verify(token),
             %{} = user <- Mokaid.Accounts.get_user(user_id) do
          {:ok, user}
        else
          _ -> :error
        end
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
