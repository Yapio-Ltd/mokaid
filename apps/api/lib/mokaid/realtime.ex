defmodule Mokaid.Realtime do
  @moduledoc """
  Broadcasts compact realtime events over Phoenix PubSub / Channels.
  Payloads are intentionally small — clients refetch details as needed.
  """

  def broadcast_workspace(workspace_id, event, payload) do
    # Endpoint.broadcast/3 already publishes through Mokaid.PubSub. Publishing
    # a second raw {:realtime, ...} tuple on the same topic makes every joined
    # WorkspaceChannel receive an unsupported handle_info message and crash.
    MokaidWeb.Endpoint.broadcast("workspace:#{workspace_id}", event, payload)
  end

  def broadcast_task(task_id, event, payload) do
    MokaidWeb.Endpoint.broadcast("task:#{task_id}", event, payload)
  end

  def broadcast_agent(agent_id, event, payload) do
    MokaidWeb.Endpoint.broadcast("agent:#{agent_id}", event, payload)
  end

  def broadcast_notification(user_id, payload) do
    MokaidWeb.Endpoint.broadcast("notifications:#{user_id}", "notification.created", payload)
  end
end
