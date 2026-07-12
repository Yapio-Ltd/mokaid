defmodule Mokaid.Repo.Migrations.CreateAgentChatConversations do
  use Ecto.Migration

  def change do
    create table(:agent_chat_conversations) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :title, :string
      add :status, :string, null: false, default: "active"

      timestamps()
    end

    create index(:agent_chat_conversations, [:workspace_id, :agent_id, :inserted_at])
    create index(:agent_chat_conversations, [:workspace_id, :agent_id, :status])

    alter table(:agent_chat_messages) do
      add :conversation_id, references(:agent_chat_conversations, on_delete: :delete_all)
    end

    create index(:agent_chat_messages, [:conversation_id])
  end
end
