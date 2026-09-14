defmodule Mokaid.AI.Workers.AgentChatWorker do
  @moduledoc """
  Direct-chat replies: when a member messages an agent in its DM thread, the
  AI worker answers in the agent's persona with awareness of its current
  workload. The reply comes back through the worker API
  (`POST /api/worker/agents/:id/chat-message`).
  """

  use Oban.Worker,
    queue: :ai_dispatch,
    max_attempts: 2,
    # Deduplicate retries of the same triggering message without dropping a
    # distinct message sent to the same agent during the uniqueness window.
    unique: [period: 60, fields: [:args], keys: [:workspace_id, :agent_id, :message_id]]

  import Ecto.Query

  alias Mokaid.AgentChat
  alias Mokaid.Agents
  alias Mokaid.Repo
  alias Mokaid.Tasks.Task

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"workspace_id" => workspace_id, "agent_id" => agent_id} = args}) do
    config = Application.fetch_env!(:mokaid, :ai_worker)
    agent = Agents.get_agent(workspace_id, agent_id)
    trigger = trigger_message(workspace_id, agent_id, args["message_id"])

    if agent == nil or trigger == nil or is_nil(trigger.conversation_id) or
         stale_trigger?(trigger) do
      :ok
    else
      # Enrich drive attachments with a short-lived download URL so the worker
      # can read PDF/DOCX/images inline (questions) without starting a task.
      attachments = enrich_attachments(workspace_id, args["attachments"] || [])

      payload = %{
        type: "agent_chat",
        workspace_id: workspace_id,
        agent_id: agent.id,
        member_id: args["member_id"],
        message_id: args["message_id"],
        conversation_id: trigger.conversation_id,
        attachments: attachments,
        agent: %{
          display_name: agent.display_name,
          role_title: agent.role_title,
          department: agent.department,
          status: agent.status,
          skills: Enum.map(agent.skills || [], &(&1["name"] || &1[:name])),
          instructions: agent.instructions
        },
        current_tasks: current_tasks(workspace_id, agent.id),
        conversation: conversation(workspace_id, agent.id, trigger.conversation_id)
      }

      # Soft: chat replies are a nicety — never crash/retry on dispatch gaps.
      # Explicit `:none` / missing URL must not fall through to Req (raises
      # ArgumentError on relative URLs like "/agent-chat").
      Mokaid.AI.WorkerClient.post("/agent-chat", payload, config: config, soft: true)
    end
  end

  # Even jobs queued before conversation_id was introduced are anchored to their
  # persisted triggering message. Missing/deleted/pre-conversation triggers cannot
  # be reassigned to today's active conversation, so those old jobs are skipped.
  defp trigger_message(workspace_id, agent_id, message_id) do
    with {:ok, id} <- Ecto.UUID.cast(message_id) do
      Repo.one(
        from m in Mokaid.AgentChat.ChatMessage,
          where:
            m.id == ^id and m.workspace_id == ^workspace_id and
              m.agent_id == ^agent_id and m.author_kind == "member"
      )
    else
      _ -> nil
    end
  end

  defp stale_trigger?(trigger) do
    scope = conversation_scope(trigger.conversation_id)

    latest_id =
      Repo.one(
        from m in Mokaid.AgentChat.ChatMessage,
          where:
            m.workspace_id == ^trigger.workspace_id and m.agent_id == ^trigger.agent_id and
              m.author_kind == "member",
          where: ^scope,
          order_by: [desc: m.inserted_at],
          limit: 1,
          select: m.id
      )

    latest_id != trigger.id
  end

  defp conversation_scope(nil), do: dynamic([m], is_nil(m.conversation_id))
  defp conversation_scope(id), do: dynamic([m], m.conversation_id == ^id)

  # Reuses Dispatcher.attached_files so chat gets the same download_url format
  # as missions — the Python direct_chat agent can then extract / vision-read.
  defp enrich_attachments(workspace_id, attachments) when is_list(attachments) do
    ids =
      attachments
      |> Enum.map(fn
        %{"drive_item_id" => id} when is_binary(id) -> id
        %{drive_item_id: id} when is_binary(id) -> id
        _ -> nil
      end)
      |> Enum.filter(&is_binary/1)

    files_by_id =
      workspace_id
      |> Mokaid.AI.Dispatcher.attached_files(ids)
      |> Map.new(fn f -> {f.id, f} end)

    Enum.map(attachments, fn entry ->
      id = entry["drive_item_id"] || entry[:drive_item_id]
      file = is_binary(id) && Map.get(files_by_id, id)

      base = %{
        "drive_item_id" => id,
        "name" => entry["name"] || entry[:name],
        "mime_type" => entry["mime_type"] || entry[:mime_type],
        "size_bytes" => entry["size_bytes"] || entry[:size_bytes]
      }

      if file do
        Map.merge(base, %{
          "name" => file.name || base["name"],
          "mime_type" => file.mime_type || base["mime_type"],
          "size_bytes" => file.size_bytes || base["size_bytes"],
          "download_url" => file.download_url
        })
      else
        base
      end
    end)
  end

  defp enrich_attachments(_workspace_id, _), do: []

  defp conversation(workspace_id, agent_id, conversation_id) do
    messages =
      case conversation_id do
        id when is_binary(id) ->
          AgentChat.list_messages_for_conversation(id, 14)

        nil ->
          Repo.all(
            from m in Mokaid.AgentChat.ChatMessage,
              where:
                m.workspace_id == ^workspace_id and m.agent_id == ^agent_id and
                  is_nil(m.conversation_id),
              order_by: [desc: m.inserted_at],
              limit: 14,
              preload: [author_member: :user]
          )
          |> Enum.reverse()
      end

    Enum.map(messages, fn message ->
      author =
        case message.author_kind do
          "agent" -> "you"
          _ -> member_name(message) || "teammate"
        end

      %{author: author, body: message.body}
    end)
  end

  defp member_name(message) do
    case message.author_member do
      %{user: %{full_name: name}} when is_binary(name) -> name
      _ -> nil
    end
  end

  defp current_tasks(workspace_id, agent_id) do
    Repo.all(
      from t in Task,
        where:
          t.workspace_id == ^workspace_id and t.assigned_agent_id == ^agent_id and
            t.status not in ["completed", "canceled"],
        order_by: [desc: t.updated_at],
        limit: 5,
        preload: [
          execution_runs:
            ^from(r in Mokaid.Tasks.TaskExecutionRun, order_by: [desc: r.inserted_at], limit: 1)
        ]
    )
    |> Enum.map(fn t ->
      latest = List.first(t.execution_runs || [])

      %{
        id: t.id,
        title: t.title,
        status: t.status,
        progress_percent: t.progress_percent,
        latest_run_status: latest && latest.status,
        conversation_id: get_in(t.metadata || %{}, ["conversation_id"]),
        source: get_in(t.metadata || %{}, ["source"])
      }
    end)
  end
end
