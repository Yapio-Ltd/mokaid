defmodule Mokaid.Members.Member do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "workspace_members" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :user, Mokaid.Accounts.User
    belongs_to :role, Mokaid.Members.Role
    belongs_to :team, Mokaid.Members.Team
    belongs_to :manager_member, __MODULE__

    field :status, :string, default: "active"
    field :title, :string
    field :joined_at, :utc_datetime_usec
    field :last_active_at, :utc_datetime_usec
    field :leave_balances, :map, default: %{}
    field :settings, :map, default: %{}

    has_one :linked_agent, Mokaid.Agents.Agent, foreign_key: :linked_member_id

    timestamps()
  end

  @statuses ~w(active invited suspended removed)

  def changeset(member, attrs) do
    member
    |> cast(attrs, [
      :workspace_id,
      :user_id,
      :role_id,
      :team_id,
      :status,
      :title,
      :manager_member_id,
      :joined_at,
      :leave_balances,
      :settings
    ])
    |> validate_required([:workspace_id, :user_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:workspace_id, :user_id])
  end
end
