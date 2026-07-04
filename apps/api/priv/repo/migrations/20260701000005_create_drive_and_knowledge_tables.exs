defmodule Mokaid.Repo.Migrations.CreateDriveAndKnowledgeTables do
  use Ecto.Migration

  def change do
    create table(:files) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :storage_key, :string, null: false
      add :bucket, :string, null: false
      add :file_name, :string, null: false
      add :mime_type, :string
      add :size_bytes, :bigint
      add :checksum, :string
      add :uploaded_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :uploaded_by_agent_id, references(:agents, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create index(:files, [:workspace_id])

    create table(:drive_items) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :parent_id, references(:drive_items, on_delete: :delete_all)
      add :kind, :string, null: false
      add :name, :string, null: false
      add :slug, :string
      add :mime_type, :string
      add :extension, :string
      add :size_bytes, :bigint
      add :storage_key, :string
      add :checksum, :string
      add :created_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :created_by_agent_id, references(:agents, on_delete: :nilify_all)
      add :last_modified_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :last_modified_by_agent_id, references(:agents, on_delete: :nilify_all)
      add :owner_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :owner_agent_id, references(:agents, on_delete: :nilify_all)
      add :linked_project_id, references(:projects, on_delete: :nilify_all)
      add :linked_task_id, references(:tasks, on_delete: :nilify_all)
      add :linked_knowledge_item_id, :binary_id
      add :linked_agent_id, references(:agents, on_delete: :nilify_all)
      add :visibility, :string, null: false, default: "workspace"
      add :status, :string, null: false, default: "active"
      add :is_ai_readable, :boolean, null: false, default: false
      add :is_system_folder, :boolean, null: false, default: false
      add :tags, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :trashed_at, :utc_datetime_usec
      add :deleted_at, :utc_datetime_usec

      timestamps()
    end

    create index(:drive_items, [:workspace_id, :parent_id])
    create index(:drive_items, [:workspace_id, :status])
    create index(:drive_items, [:workspace_id, :linked_project_id])
    create index(:drive_items, [:workspace_id, :linked_task_id])

    create constraint(:drive_items, :folder_has_no_storage_key,
             check: "kind != 'folder' OR storage_key IS NULL"
           )

    create constraint(:drive_items, :file_requires_storage_key,
             check: "kind != 'file' OR storage_key IS NOT NULL"
           )

    create table(:drive_item_versions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :drive_item_id, references(:drive_items, on_delete: :delete_all), null: false
      add :version_number, :integer, null: false
      add :storage_key, :string, null: false
      add :size_bytes, :bigint
      add :checksum, :string
      add :created_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :created_by_agent_id, references(:agents, on_delete: :nilify_all)
      add :change_summary, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(updated_at: false)
    end

    create unique_index(:drive_item_versions, [:drive_item_id, :version_number])

    create table(:drive_item_permissions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :drive_item_id, references(:drive_items, on_delete: :delete_all), null: false
      add :subject_type, :string, null: false
      add :subject_id, :binary_id, null: false
      add :permission, :string, null: false
      add :granted_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :expires_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:drive_item_permissions, [:drive_item_id, :subject_type, :subject_id])

    create table(:drive_item_comments) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :drive_item_id, references(:drive_items, on_delete: :delete_all), null: false
      add :created_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :created_by_agent_id, references(:agents, on_delete: :nilify_all)
      add :body, :text, null: false
      add :parent_comment_id, references(:drive_item_comments, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}
      add :deleted_at, :utc_datetime_usec

      timestamps()
    end

    create index(:drive_item_comments, [:drive_item_id])

    create table(:drive_item_activity_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :drive_item_id, references(:drive_items, on_delete: :delete_all), null: false
      add :actor_type, :string, null: false
      add :actor_id, :binary_id
      add :actor_name, :string
      add :event_type, :string, null: false
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:drive_item_activity_events, [:workspace_id, :drive_item_id, :occurred_at])

    create table(:knowledge_categories) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :color, :string
      add :position, :integer, null: false, default: 0

      timestamps()
    end

    create unique_index(:knowledge_categories, [:workspace_id, :name])

    create table(:knowledge_items) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :category_id, references(:knowledge_categories, on_delete: :nilify_all)
      add :created_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :title, :string, null: false
      add :type, :string, null: false
      add :source_url, :string
      add :file_id, references(:files, on_delete: :nilify_all)
      add :drive_item_id, references(:drive_items, on_delete: :nilify_all)
      add :body, :text
      add :status, :string, null: false, default: "draft"
      add :visibility, :string, null: false, default: "workspace"
      add :tags, {:array, :string}, null: false, default: []
      add :version, :integer, null: false, default: 1
      add :indexing_status, :string, null: false, default: "not_indexed"
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create index(:knowledge_items, [:workspace_id, :category_id])
    create index(:knowledge_items, [:workspace_id, :status])

    create table(:knowledge_chunks) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :knowledge_item_id, references(:knowledge_items, on_delete: :delete_all), null: false
      add :chunk_index, :integer, null: false
      add :content, :text, null: false
      add :embedding, :vector, size: 1536
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:knowledge_chunks, [:knowledge_item_id, :chunk_index])
    create index(:knowledge_chunks, [:workspace_id])

    create table(:knowledge_permissions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :knowledge_item_id, references(:knowledge_items, on_delete: :delete_all)
      add :category_id, references(:knowledge_categories, on_delete: :delete_all)
      add :subject_type, :string, null: false
      add :subject_id, :binary_id, null: false
      add :permission, :string, null: false, default: "view"
      add :granted_by_member_id, references(:workspace_members, on_delete: :nilify_all)

      timestamps()
    end

    create index(:knowledge_permissions, [:workspace_id, :knowledge_item_id])
  end
end
