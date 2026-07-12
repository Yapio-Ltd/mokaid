defmodule MokaidWeb.AgentChatController do
  use MokaidWeb, :controller

  alias Mokaid.AgentChat
  alias Mokaid.Agents
  alias MokaidWeb.JSON, as: Serializer

  @doc "Conversation summaries for the floating dock: last message + unread count."
  def index(conn, _params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view") do
      summaries = AgentChat.summaries(workspace_id(conn), current_member(conn).id)

      json(conn, %{
        data:
          Enum.map(summaries, fn summary ->
            %{
              agent_id: summary.agent_id,
              conversation_id: summary.conversation_id,
              unread_count: summary.unread_count,
              last_message: Serializer.agent_chat_message(summary.last_message)
            }
          end)
      })
    end
  end

  def show(conn, %{"agent_id" => agent_id} = params) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = _agent <- Agents.get_agent(workspace_id(conn), agent_id) do
      messages =
        case params["conversation_id"] do
          conv_id when is_binary(conv_id) and conv_id != "" ->
            AgentChat.list_messages_for_conversation(conv_id)

          _ ->
            AgentChat.list_messages(workspace_id(conn), agent_id)
        end

      json(conn, %{data: Enum.map(messages, &Serializer.agent_chat_message/1)})
    end
  end

  def create(conn, %{"agent_id" => agent_id} = params) do
    body = params["body"] || ""
    attachments = build_attachments(workspace_id(conn), List.wrap(params["drive_item_ids"]))

    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), agent_id),
         {:ok, message} <-
           AgentChat.post_member_message(
             workspace_id(conn),
             agent,
             current_member(conn),
             body,
             attachments: attachments
           ) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.agent_chat_message(message)})
    end
  end

  @doc "List all conversations for an agent (newest first)."
  def conversations(conn, %{"agent_id" => agent_id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = _agent <- Agents.get_agent(workspace_id(conn), agent_id) do
      conversations = AgentChat.list_conversations(workspace_id(conn), agent_id)
      json(conn, %{data: Enum.map(conversations, &Serializer.agent_chat_conversation/1)})
    end
  end

  @doc "Start a new conversation with the agent (archives the previous one)."
  def new_conversation(conn, %{"agent_id" => agent_id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = _agent <- Agents.get_agent(workspace_id(conn), agent_id),
         {:ok, conv} <-
           AgentChat.new_conversation(
             workspace_id(conn),
             agent_id,
             current_member(conn).id
           ) do
      conn
      |> put_status(:created)
      |> json(%{data: Serializer.agent_chat_conversation(conv)})
    end
  end

  defp build_attachments(_workspace_id, []), do: []

  defp build_attachments(workspace_id, drive_item_ids) do
    ids = Enum.filter(drive_item_ids, &is_binary/1)

    Mokaid.Drive.list_items_by_ids(workspace_id, ids)
    |> Enum.map(fn item ->
      %{
        "drive_item_id" => item.id,
        "name" => item.name,
        "mime_type" => item.mime_type,
        "size_bytes" => item.size_bytes
      }
    end)
  end

  def mark_read(conn, %{"agent_id" => agent_id}) do
    with :ok <- Permissions.authorize(current_member(conn), "agents.view"),
         %{} = agent <- Agents.get_agent(workspace_id(conn), agent_id) do
      AgentChat.mark_read(workspace_id(conn), agent.id, current_member(conn).id)
      json(conn, %{data: %{ok: true}})
    end
  end
end
