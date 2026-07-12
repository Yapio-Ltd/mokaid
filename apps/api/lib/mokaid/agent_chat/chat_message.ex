defmodule Mokaid.AgentChat.ChatMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_chat_messages" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :agent, Mokaid.Agents.Agent
    belongs_to :conversation, Mokaid.AgentChat.Conversation
    belongs_to :author_member, Mokaid.Members.Member
    belongs_to :task, Mokaid.Tasks.Task

    field :author_kind, :string
    field :body, :string
    field :attachments, {:array, :map}, default: []

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :workspace_id,
      :agent_id,
      :conversation_id,
      :author_kind,
      :author_member_id,
      :body,
      :attachments,
      :task_id
    ])
    |> validate_required([:workspace_id, :agent_id, :author_kind])
    |> validate_inclusion(:author_kind, ~w(member agent))
    |> validate_length(:body, max: 8_000)
    |> validate_body_or_attachments()
  end

  # A message is valid if it has text or at least one attachment (a member can
  # drop a file with no caption; an agent can deliver files with a short note).
  defp validate_body_or_attachments(changeset) do
    body = get_field(changeset, :body)
    attachments = get_field(changeset, :attachments) || []

    if (is_binary(body) and String.trim(body) != "") or attachments != [] do
      changeset
    else
      add_error(changeset, :body, "a message needs text or an attachment")
    end
  end
end
