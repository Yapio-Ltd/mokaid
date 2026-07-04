defmodule Mokaid.Notifications.Notification do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "notifications" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :user, Mokaid.Accounts.User

    field :kind, :string
    field :title, :string
    field :body, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :read_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:workspace_id, :user_id, :kind, :title, :body, :resource_type, :resource_id])
    |> validate_required([:workspace_id, :user_id, :kind, :title])
  end
end
