defmodule Mokaid.Repo.Migrations.AddAgentAutonomy do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :autonomy_mode, :string, default: "balanced", null: false
    end

    create table(:agent_permission_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :tool_pattern, :string, null: false
      add :behavior, :string, null: false, default: "allow"

      add :created_by_member_id,
          references(:workspace_members, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_permission_rules, [:workspace_id])
    create unique_index(:agent_permission_rules, [:agent_id, :tool_pattern],
             name: :agent_permission_rules_agent_tool_unique
           )
  end
end
