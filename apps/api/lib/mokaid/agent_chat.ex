defmodule Mokaid.AgentChat do
  @moduledoc """
  Direct conversations between workspace members and AI agents — the
  agent-level DM threads behind the floating chat dock.

  The chat is a two-way work surface, not just small talk: a member can drop
  files or ask for a deliverable, which spins up a real task assigned to that
  agent; when the run finishes, the agent delivers its output back into this
  thread with a natural message plus the produced files as attachments.
  """

  import Ecto.Query

  alias Mokaid.AgentChat.{ChatMessage, ChatRead}
  alias Mokaid.Agents
  alias Mokaid.Realtime
  alias Mokaid.Repo

  @history_limit 50

  def list_messages(workspace_id, agent_id, limit \\ @history_limit) do
    Repo.all(
      from m in ChatMessage,
        where: m.workspace_id == ^workspace_id and m.agent_id == ^agent_id,
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        preload: [author_member: :user]
    )
    |> Enum.reverse()
  end

  @doc """
  Member sends a message to an agent. Inserts, broadcasts, marks the sender's
  own cursor as read, and then decides what the agent does:

  - Files dropped, or an explicit ask for a deliverable → start a real task
    assigned to this agent (the agent posts an acknowledgement, works, and
    delivers the output back into this thread on completion).
  - Otherwise → a conversational reply (AgentChatWorker).
  """
  def post_member_message(workspace_id, agent, member, body, opts \\ []) do
    attachments = normalize_attachments(Keyword.get(opts, :attachments, []))

    result =
      %ChatMessage{}
      |> ChatMessage.changeset(%{
        "workspace_id" => workspace_id,
        "agent_id" => agent.id,
        "author_kind" => "member",
        "author_member_id" => member.id,
        "body" => body,
        "attachments" => attachments
      })
      |> Repo.insert()

    with {:ok, message} <- result do
      message = Repo.preload(message, author_member: :user)
      mark_read(workspace_id, agent.id, member.id)
      broadcast_message(message)

      if agent.kind != "human_linked" do
        route_member_message(workspace_id, agent, member, message, attachments)
      end

      {:ok, message}
    end
  end

  @doc "Agent reply coming back from the AI worker (optionally with files)."
  def post_agent_message(workspace_id, agent_id, body, opts \\ []) do
    attachments = normalize_attachments(Keyword.get(opts, :attachments, []))

    result =
      %ChatMessage{}
      |> ChatMessage.changeset(%{
        "workspace_id" => workspace_id,
        "agent_id" => agent_id,
        "author_kind" => "agent",
        "body" => body,
        "attachments" => attachments,
        "task_id" => Keyword.get(opts, :task_id)
      })
      |> Repo.insert()

    with {:ok, message} <- result do
      Repo.update_all(
        from(a in Agents.Agent, where: a.workspace_id == ^workspace_id and a.id == ^agent_id),
        set: [last_active_at: DateTime.utc_now()]
      )

      broadcast_message(message)
      {:ok, message}
    end
  end

  @doc """
  Delivers a finished run's output into the agent's chat thread: a natural
  message plus the produced files as attachments. Called from AI completion
  when the task was launched from chat (`metadata.chat_agent_id`).
  """
  def deliver_task_output(workspace_id, agent_id, body, output_items) do
    post_agent_message(workspace_id, agent_id, body, attachments: output_items)
  end

  def mark_read(workspace_id, agent_id, member_id) do
    now = DateTime.utc_now()

    Repo.insert!(
      %ChatRead{
        workspace_id: workspace_id,
        agent_id: agent_id,
        member_id: member_id,
        last_read_at: now
      },
      on_conflict: [set: [last_read_at: now, updated_at: now]],
      conflict_target: [:agent_id, :member_id]
    )

    :ok
  end

  @doc """
  One entry per agent conversation for the dock: last message + the caller's
  unread count (agent-authored messages after their read cursor).
  """
  def summaries(workspace_id, member_id) do
    last_messages =
      Repo.all(
        from m in ChatMessage,
          where: m.workspace_id == ^workspace_id,
          distinct: m.agent_id,
          order_by: [asc: m.agent_id, desc: m.inserted_at],
          preload: [author_member: :user]
      )

    unread =
      Repo.all(
        from m in ChatMessage,
          left_join: r in ChatRead,
          on: r.agent_id == m.agent_id and r.member_id == ^member_id,
          where:
            m.workspace_id == ^workspace_id and m.author_kind == "agent" and
              (is_nil(r.id) or m.inserted_at > r.last_read_at),
          group_by: m.agent_id,
          select: {m.agent_id, count(m.id)}
      )
      |> Map.new()

    last_messages
    |> Enum.map(fn message ->
      %{
        agent_id: message.agent_id,
        last_message: message,
        unread_count: Map.get(unread, message.agent_id, 0)
      }
    end)
    |> Enum.sort_by(& &1.last_message.inserted_at, {:desc, DateTime})
  end

  ## ---------- Routing: conversation vs. work ----------

  # Files always mean work. Text-only messages are classified by the AI worker
  # (chat vs. actionable request) so a plain "how's it going?" doesn't spin up
  # a task — we let the worker decide and start the task from its callback.
  defp route_member_message(workspace_id, agent, member, message, attachments) do
    if attachments != [] do
      start_chat_task(workspace_id, agent, member, message, attachments)
    else
      # No files: the worker replies conversationally, and if it judges the
      # message to be an actionable work request it asks us to start a task.
      Realtime.broadcast_workspace(workspace_id, "agent_chat.typing", %{agent_id: agent.id})

      %{workspace_id: workspace_id, agent_id: agent.id, member_id: member.id}
      |> Mokaid.AI.Workers.AgentChatWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  Starts a task from a chat message: assigned to this agent, seeded with the
  chat text and any dropped files, tagged so the run's output comes back to
  this thread. Posts an acknowledgement message and returns the task.
  """
  def start_chat_task(workspace_id, agent, member, message, attachments) do
    drive_ids = Enum.map(attachments, & &1["drive_item_id"]) |> Enum.filter(&is_binary/1)
    instruction = message_instruction(message, attachments)

    with {:ok, task} <-
           Mokaid.Tasks.create_task(
             workspace_id,
             %{
               "title" => chat_task_title(instruction, attachments),
               "description" => instruction,
               "priority" => "medium",
               "assigned_agent_id" => agent.id,
               "metadata" => %{
                 "source" => "chat",
                 "chat_agent_id" => agent.id,
                 "instruction" => instruction,
                 "drive_item_ids" => drive_ids
               }
             },
             member
           ) do
      link_drive_items(workspace_id, task.id, drive_ids)

      # Immediate acknowledgement in the chat itself, before the run starts —
      # the teammate sees "on it" right away, in the thread they're looking at.
      post_agent_message(workspace_id, agent.id, acknowledgement_message(instruction),
        task_id: task.id
      )

      if agent.kind != "human_linked" do
        # chat_task: true tells the worker to skip the task-thread
        # acknowledgement comment — the chat already got its "on it" reply, and
        # we don't want a parallel conversation living in the task menu.
        Mokaid.AI.start_run(task, %{
          "instruction" => instruction,
          "drive_item_ids" => drive_ids,
          "chat_task" => true
        })
      end

      {:ok, task}
    end
  end

  # A warm, natural "I'm on it" line in the teammate's language.
  defp acknowledgement_message(instruction) do
    if french?(instruction) do
      "Oui, bien sûr ! Je m'en occupe tout de suite — je te montre le résultat ici dès que c'est prêt. 👍"
    else
      "On it! I'll get this done and share the result right here as soon as it's ready. 👍"
    end
  end

  defp french?(text) when is_binary(text) do
    Regex.match?(
      ~r/\b(je|tu|le|la|les|un|une|pour|avec|dans|que|qui|fais|génère|créer?|change|voici|s'il|à|é|è|ê|ç)\b/iu,
      text
    )
  end

  defp french?(_), do: false

  defp message_instruction(%ChatMessage{body: body}, attachments) do
    text = (body || "") |> String.trim()

    cond do
      text != "" -> text
      attachments != [] -> "Work with the attached file(s) and produce the requested result."
      true -> "Handle this request."
    end
  end

  defp chat_task_title(instruction, attachments) do
    base =
      instruction
      |> String.split(~r/[.\n!?]/, parts: 2)
      |> List.first()
      |> String.trim()
      |> String.slice(0, 80)

    cond do
      base != "" -> base
      attachments != [] -> "Work on #{List.first(attachments)["name"] || "attached file"}"
      true -> "Chat request"
    end
  end

  defp link_drive_items(_workspace_id, _task_id, []), do: :ok

  defp link_drive_items(workspace_id, task_id, drive_ids) do
    from(d in Mokaid.Drive.DriveItem,
      where: d.workspace_id == ^workspace_id and d.id in ^drive_ids
    )
    |> Repo.update_all(set: [linked_task_id: task_id])
  end

  ## ---------- Helpers ----------

  defp normalize_attachments(list) when is_list(list) do
    Enum.flat_map(list, fn entry ->
      map = normalize_attachment_entry(entry)
      if is_binary(map["drive_item_id"]), do: [map], else: []
    end)
  end

  defp normalize_attachments(_), do: []

  defp normalize_attachment_entry(entry) when is_map(entry) do
    %{
      "drive_item_id" => entry["drive_item_id"] || entry[:drive_item_id],
      "name" => entry["name"] || entry[:name],
      "mime_type" => entry["mime_type"] || entry[:mime_type],
      "size_bytes" => entry["size_bytes"] || entry[:size_bytes]
    }
  end

  defp normalize_attachment_entry(_), do: %{}

  defp broadcast_message(%ChatMessage{} = message) do
    Realtime.broadcast_workspace(message.workspace_id, "agent_chat.message", %{
      agent_id: message.agent_id,
      message_id: message.id,
      author_kind: message.author_kind,
      body: message.body,
      has_attachments: message.attachments != [],
      inserted_at: message.inserted_at
    })
  end
end
