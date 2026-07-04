defmodule Mokaid.Repo.Migrations.CreateCalendarBillingIntegrationTables do
  use Ecto.Migration

  def change do
    create table(:calendar_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :description, :text
      add :kind, :string, null: false, default: "event"
      add :start_at, :utc_datetime_usec, null: false
      add :end_at, :utc_datetime_usec
      add :all_day, :boolean, null: false, default: false
      add :member_id, references(:workspace_members, on_delete: :nilify_all)
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :project_id, references(:projects, on_delete: :nilify_all)
      add :task_id, references(:tasks, on_delete: :nilify_all)
      add :leave_request_id, :binary_id
      add :color, :string
      add :metadata, :map, null: false, default: %{}

      timestamps()
    end

    create index(:calendar_events, [:workspace_id, :start_at])

    create table(:leave_requests) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :member_id, references(:workspace_members, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :start_at, :utc_datetime_usec, null: false
      add :end_at, :utc_datetime_usec, null: false
      add :reason, :text
      add :attachment_file_id, references(:files, on_delete: :nilify_all)
      add :reviewed_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime_usec
      add :review_note, :text

      timestamps()
    end

    create index(:leave_requests, [:workspace_id, :status])
    create index(:leave_requests, [:workspace_id, :member_id])

    create table(:integration_providers) do
      add :key, :string, null: false
      add :name, :string, null: false
      add :category, :string, null: false
      add :description, :text
      add :icon_slug, :string
      add :auth_kind, :string, null: false, default: "oauth2"
      add :capabilities, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true

      timestamps()
    end

    create unique_index(:integration_providers, [:key])

    create table(:integration_connections) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :provider_id, references(:integration_providers, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "disconnected"
      add :connected_account, :string
      add :connected_by_member_id, references(:workspace_members, on_delete: :nilify_all)
      add :encrypted_credentials, :binary
      add :permissions, :map, null: false, default: %{}
      add :last_sync_at, :utc_datetime_usec
      add :settings, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:integration_connections, [:workspace_id, :provider_id])

    create table(:webhook_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :connection_id, references(:integration_connections, on_delete: :delete_all)
      add :provider_key, :string
      add :event_type, :string, null: false
      add :direction, :string, null: false, default: "inbound"
      add :status, :string, null: false, default: "received"
      add :payload, :map, null: false, default: %{}
      add :error, :text
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:webhook_events, [:workspace_id, :occurred_at])

    create table(:billing_plans) do
      add :key, :string, null: false
      add :name, :string, null: false
      add :price_cents_monthly, :integer, null: false, default: 0
      add :price_cents_yearly, :integer, null: false, default: 0
      add :limits, :map, null: false, default: %{}
      add :features, {:array, :string}, null: false, default: []

      timestamps()
    end

    create unique_index(:billing_plans, [:key])

    create table(:subscriptions) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :plan_id, references(:billing_plans, on_delete: :nilify_all)
      add :status, :string, null: false, default: "active"
      add :billing_cycle, :string, null: false, default: "monthly"
      add :current_period_start, :utc_datetime_usec
      add :current_period_end, :utc_datetime_usec
      add :external_customer_id, :string
      add :external_subscription_id, :string
      add :payment_method, :map, null: false, default: %{}

      timestamps()
    end

    create unique_index(:subscriptions, [:workspace_id])

    create table(:invoices) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :subscription_id, references(:subscriptions, on_delete: :nilify_all)
      add :number, :string, null: false
      add :status, :string, null: false, default: "draft"
      add :amount_cents, :integer, null: false, default: 0
      add :currency, :string, null: false, default: "USD"
      add :issued_at, :utc_datetime_usec
      add :paid_at, :utc_datetime_usec
      add :line_items, {:array, :map}, null: false, default: []

      timestamps()
    end

    create unique_index(:invoices, [:workspace_id, :number])

    create table(:usage_events) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :actor_type, :string, null: false
      add :actor_id, :binary_id
      add :event_type, :string, null: false
      add :quantity, :decimal, null: false, default: 1
      add :unit, :string, null: false
      add :cost_cents, :integer, null: false, default: 0
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:usage_events, [:workspace_id, :event_type, :occurred_at])

    create table(:audit_logs) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all)
      add :actor_type, :string, null: false
      add :actor_id, :binary_id
      add :actor_name, :string
      add :action, :string, null: false
      add :resource_type, :string
      add :resource_id, :binary_id
      add :ip_address, :string
      add :user_agent, :string
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(updated_at: false)
    end

    create index(:audit_logs, [:workspace_id, :occurred_at])
    create index(:audit_logs, [:workspace_id, :action])

    create table(:notifications) do
      add :workspace_id, references(:workspaces, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :title, :string, null: false
      add :body, :text
      add :resource_type, :string
      add :resource_id, :binary_id
      add :read_at, :utc_datetime_usec

      timestamps()
    end

    create index(:notifications, [:user_id, :read_at])
  end
end
