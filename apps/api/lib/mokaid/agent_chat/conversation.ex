defmodule Mokaid.AgentChat.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agent_chat_conversations" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :agent, Mokaid.Agents.Agent

    field :title, :string
    field :status, :string, default: "active"

    has_many :messages, Mokaid.AgentChat.ChatMessage

    timestamps()
  end

  @statuses ~w(active archived)

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:workspace_id, :agent_id, :title, :status])
    |> validate_required([:workspace_id, :agent_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:title, max: 200)
  end
end
