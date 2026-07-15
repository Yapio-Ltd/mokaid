defmodule Mokaid.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "agents" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :linked_user, Mokaid.Accounts.User
    belongs_to :linked_member, Mokaid.Members.Member
    belongs_to :manager_agent, __MODULE__
    belongs_to :created_by_member, Mokaid.Members.Member

    field :kind, :string
    field :display_name, :string
    field :slug, :string
    field :email_alias, :string
    field :avatar_config, :map, default: %{}
    field :avatar_asset_id, :string
    field :role_title, :string
    field :department, :string
    field :status, :string, default: "idle"
    field :presence_status, :string, default: "online"
    field :control_mode, :string, default: "ai_controlled"
    field :ai_enabled, :boolean, default: false
    field :human_takeover_enabled, :boolean, default: false
    field :skills, {:array, :map}, default: []
    field :capabilities, :map, default: %{}
    field :current_task_id, :binary_id
    field :performance_score, :decimal
    # Gamified progression: missions earn XP; levels unlock as XP accumulates.
    field :level, :integer, default: 1
    field :xp, :integer, default: 0
    field :xp_for_next_level, :integer, default: 100
    field :missions_completed, :integer, default: 0
    field :access_scope, :map, default: %{}
    field :last_active_at, :utc_datetime_usec
    field :archived_at, :utc_datetime_usec
    # 3D office: unique desk 0..8 per workspace; social POI presence is ephemeral.
    field :seat_index, :integer
    field :office_activity, :string
    field :office_poi_id, :string
    field :office_slot_id, :string
    field :office_activity_phase, :string
    field :office_activity_ends_at, :utc_datetime_usec

    timestamps()
  end

  @kinds ~w(ai human_linked hybrid)
  @statuses ~w(active busy idle waiting blocked away offline archived)
  @presences ~w(online offline away)
  @office_activities ~w(preparing_coffee playing_foosball sitting_sofa walking scrolling stretching looking_around)
  @office_phases ~w(approaching entering active leaving)

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :workspace_id,
      :linked_user_id,
      :linked_member_id,
      :kind,
      :display_name,
      :slug,
      :email_alias,
      :avatar_config,
      :avatar_asset_id,
      :role_title,
      :department,
      :manager_agent_id,
      :status,
      :presence_status,
      :control_mode,
      :ai_enabled,
      :human_takeover_enabled,
      :skills,
      :capabilities,
      :current_task_id,
      :performance_score,
      :level,
      :xp,
      :xp_for_next_level,
      :missions_completed,
      :access_scope,
      :created_by_member_id,
      :last_active_at,
      :seat_index,
      :office_activity,
      :office_poi_id,
      :office_slot_id,
      :office_activity_phase,
      :office_activity_ends_at
    ])
    |> validate_required([:workspace_id, :kind, :display_name])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:presence_status, @presences)
    |> validate_number(:seat_index, greater_than_or_equal_to: 0, less_than_or_equal_to: 8)
    |> validate_optional_inclusion(:office_activity, @office_activities)
    |> validate_optional_inclusion(:office_activity_phase, @office_phases)
    |> put_slug()
    |> validate_linked_user()
    |> unique_constraint([:workspace_id, :slug])
    |> unique_constraint([:workspace_id, :seat_index], name: :agents_workspace_seat_index_unique)
    |> check_constraint(:linked_user_id, name: :human_linked_requires_user)
  end

  def office_activity_changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :office_activity,
      :office_poi_id,
      :office_slot_id,
      :office_activity_phase,
      :office_activity_ends_at
    ])
    |> validate_optional_inclusion(:office_activity, @office_activities)
    |> validate_optional_inclusion(:office_activity_phase, @office_phases)
  end

  defp validate_optional_inclusion(changeset, field, values) do
    case get_change(changeset, field, :__absent__) do
      :__absent__ -> changeset
      nil -> changeset
      _ -> validate_inclusion(changeset, field, values)
    end
  end

  defp put_slug(changeset) do
    case {get_field(changeset, :slug), get_change(changeset, :display_name)} do
      {nil, name} when is_binary(name) ->
        slug =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "-")
          |> String.trim("-")

        put_change(changeset, :slug, "#{slug}-#{random_suffix()}")

      _ ->
        changeset
    end
  end

  defp random_suffix do
    :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
  end

  defp validate_linked_user(changeset) do
    kind = get_field(changeset, :kind)
    linked_user_id = get_field(changeset, :linked_user_id)

    case {kind, linked_user_id} do
      {"human_linked", nil} ->
        add_error(changeset, :linked_user_id, "is required for human-linked agents")

      {"ai", user_id} when not is_nil(user_id) ->
        add_error(changeset, :linked_user_id, "must be empty for AI-only agents")

      _ ->
        changeset
    end
  end

  def status_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:status, :presence_status, :control_mode, :current_task_id, :last_active_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:presence_status, @presences)
  end
end
