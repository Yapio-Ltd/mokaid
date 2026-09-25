defmodule Mokaid.Repo.Migrations.CreateAvatarGenerations do
  use Ecto.Migration

  def change do
    alter table(:asset_3d) do
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all)
    end

    create index(:asset_3d, [:workspace_id])

    create table(:avatar_generations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_id, references(:workspaces, type: :uuid, on_delete: :delete_all), null: false

      add :created_by_member_id,
          references(:workspace_members, type: :uuid, on_delete: :nilify_all)

      add :asset_id, references(:asset_3d, type: :uuid, on_delete: :nilify_all)
      add :mode, :text, null: false
      add :name, :text, null: false
      add :prompt, :text
      add :source_storage_key, :text
      add :status, :text, null: false, default: "queued"
      add :progress, :integer, null: false, default: 0
      add :task_id, :text
      add :task_kind, :text
      add :thumbnail_source_url, :text
      add :thumbnail_url, :text
      add :error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:avatar_generations, [:workspace_id, :inserted_at])
    create unique_index(:avatar_generations, [:task_id])

    create table(:meshy_webhook_deliveries, primary_key: false) do
      add :digest, :string, primary_key: true
      add :inserted_at, :utc_datetime_usec, null: false
    end
  end
end
