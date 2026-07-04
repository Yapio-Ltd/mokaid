defmodule Mokaid.Repo.Migrations.CreateProjectAndTaskTables do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "planning"
      add :priority, :string, null: false, default: "medium"
      add :progress_percent, :integer, null: false, default: 0
      add :owner_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :start_at, :utc_datetime_usec
      add :due_at, :utc_datetime_usec
      add :cover_kind, :string
      add :drive_folder_id, :binary_id
      add :metadata, :map, null: false, default: %{}
      add :archived_at, :utc_datetime_usec

      timestamps()
    end

    create index(:projects, [:workspace_id, :status])

    create table(:project_members) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :member_id, references(:workspace_members, on_delete: :delete_all), null: false
      add :role, :string, default: "contributor"

      timestamps()
    end

    create unique_index(:project_members, [:project_id, :member_id])

    create table(:project_agents) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:project_agents, [:project_id, :agent_id])

    create table(:project_files) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :drive_item_id, :binary_id
      add :label, :string

      timestamps()
    end

    create index(:project_files, [:project_id])

    create table(:project_activity_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :actor_type, :string, null: false
      add :actor_id, :binary_id
      add :actor_name, :string
      add :event_type, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:project_activity_events, [:workspace_id, :project_id, :occurred_at])

    create table(:tasks) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :project_id, references(:projects, on_delete: :nilify_all)
      add :title, :string, null: false
      add :description, :text
      add :status, :string, null: false, default: "to_do"
      add :priority, :string, null: false, default: "medium"
      add :assigned_agent_id, references(:agents, on_delete: :nilify_all)
      add :assigned_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :created_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :due_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :progress_percent, :integer, null: false, default: 0
      add :requires_approval, :boolean, null: false, default: false
      add :tags, {:array, :string}, null: false, default: []
      add :position, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create index(:tasks, [:workspace_id, :status])
    create index(:tasks, [:workspace_id, :assigned_agent_id])
    create index(:tasks, [:workspace_id, :project_id])
    create index(:tasks, [:workspace_id, :due_at])

    create table(:subtasks) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :done, :boolean, null: false, default: false
      add :position, :integer, null: false, default: 0

      timestamps()
    end

    create index(:subtasks, [:task_id])

    create table(:task_assignments) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :delete_all)
      add :member_id, references(:workspace_members, on_delete: :delete_all)
      add :assigned_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :unassigned_at, :utc_datetime_usec

      timestamps()
    end

    create index(:task_assignments, [:task_id])

    create table(:task_comments) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :author_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :author_agent_id, references(:agents, on_delete: :nilify_all)
      add :body, :text, null: false
      add :deleted_at, :utc_datetime_usec

      timestamps()
    end

    create index(:task_comments, [:task_id])

    create table(:task_attachments) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :drive_item_id, :binary_id
      add :file_name, :string, null: false
      add :kind, :string, default: "attachment"
      add :added_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :added_by_agent_id, references(:agents, on_delete: :nilify_all)

      timestamps()
    end

    create index(:task_attachments, [:task_id])

    create table(:task_activity_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :actor_type, :string, null: false
      add :actor_id, :binary_id
      add :actor_name, :string
      add :event_type, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:task_activity_events, [:workspace_id, :task_id, :occurred_at])

    create table(:task_execution_runs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :status, :string, null: false, default: "queued"
      add :input, :map, null: false, default: %{}
      add :steps, {:array, :map}, null: false, default: []
      add :tool_calls, {:array, :map}, null: false, default: []
      add :output, :map
      add :error, :text
      add :token_usage, :map, null: false, default: %{}
      add :cost_cents, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps()
    end

    create index(:task_execution_runs, [:workspace_id, :task_id])
    create index(:task_execution_runs, [:workspace_id, :status])

    create table(:task_approval_requests) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :run_id, references(:task_execution_runs, on_delete: :delete_all)
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :tool_name, :string, null: false
      add :risk_level, :string, null: false, default: "medium"
      add :proposed_action, :text, null: false
      add :input_payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :reviewed_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime_usec
      add :decision_payload, :map

      timestamps()
    end

    create index(:task_approval_requests, [:workspace_id, :status])
    create index(:task_approval_requests, [:task_id])
  end
end
