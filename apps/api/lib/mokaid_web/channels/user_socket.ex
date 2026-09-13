defmodule MokaidWeb.UserSocket do
  use Phoenix.Socket

  # Extend transport callbacks, preserving Phoenix serialization and heartbeat
  # semantics. Native tokens are never accepted from URL query parameters.
  defoverridable init: 1, handle_in: 2, handle_info: 2

  channel "workspace:*", MokaidWeb.WorkspaceChannel
  channel "task:*", MokaidWeb.TaskChannel
  channel "agent:*", MokaidWeb.AgentChannel
  channel "notifications:*", MokaidWeb.NotificationChannel

  @impl true
  def connect(params, socket, connect_info) do
    with {:ok, token} <- bearer_token(params, connect_info),
         {:ok, user, metadata} <- Mokaid.Auth.Session.authenticate(token),
         true <- Mokaid.Auth.ClientPolicy.channels_allowed?(metadata) do
      {:ok, socket |> assign(:current_user, user) |> assign(:auth_session, metadata)}
    else
      _ -> :error
    end
  end

  defp bearer_token(params, connect_info) do
    case List.keyfind(Map.get(connect_info, :x_headers, []), "x-mokaid-authorization", 0) do
      {_, "Bearer " <> token} ->
        {:ok, token}

      nil ->
        case params do
          %{"token" => token} when is_binary(token) ->
            if Mokaid.Auth.Desktop.access_token?(token), do: :error, else: {:ok, token}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  @impl true
  def init({_, _socket} = state) do
    # Also recheck browser sockets already connected before a live rollout change.
    Process.send_after(self(), :auth_session_check, 15_000)
    super(state)
  end

  @impl true
  def handle_in(message, state) do
    if authorized?(state), do: super(message, state), else: {:stop, :normal, state}
  end

  @impl true
  def handle_info(check, state)
      when check in [:auth_session_check, :desktop_session_check] do
    if authorized?(state) do
      Process.send_after(self(), :auth_session_check, 15_000)
      {:ok, state}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info({:socket_push, _, _} = message, state) do
    if authorized?(state), do: super(message, state), else: {:stop, :normal, state}
  end

  def handle_info(message, state), do: super(message, state)

  defp authorized?({transport, socket}) do
    metadata = Map.get(socket.assigns, :auth_session, %{})

    Mokaid.Auth.ClientPolicy.channels_allowed?(metadata) and session_active?(metadata, socket) and
      MokaidWeb.ChannelAccess.allowed?(
        socket.assigns.current_user.id,
        Map.get(transport, :channels)
      )
  end

  defp session_active?(metadata, socket) do
    case metadata do
      %{desktop_session_id: id, access_expires_at: expires} ->
        expires > System.system_time(:second) and
          match?(
            {:ok, _},
            Mokaid.Auth.Desktop.validate_session(id, socket.assigns.current_user.id)
          )

      _ ->
        socket.assigns.current_user.id
        |> Mokaid.Accounts.get_user()
        |> Mokaid.Accounts.User.active?()
    end
  end

  @impl true
  def id(%{assigns: %{auth_session: %{desktop_session_id: id}}}), do: "desktop_session:" <> id
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
