defmodule Mokaid.Members.LeaveRequest do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "leave_requests" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :member, Mokaid.Members.Member
    belongs_to :agent, Mokaid.Agents.Agent
    belongs_to :reviewed_by_member, Mokaid.Members.Member

    field :type, :string
    field :status, :string, default: "pending"
    field :start_at, :utc_datetime_usec
    field :end_at, :utc_datetime_usec
    field :reason, :string
    field :attachment_file_id, :binary_id
    field :reviewed_at, :utc_datetime_usec
    field :review_note, :string

    timestamps()
  end

  @types ~w(vacation sick_leave remote_work other)

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:workspace_id, :member_id, :agent_id, :type, :start_at, :end_at, :reason])
    |> validate_required([:workspace_id, :member_id, :type, :start_at, :end_at])
    |> validate_inclusion(:type, @types)
    |> validate_date_order()
  end

  def review_changeset(request, attrs) do
    request
    |> cast(attrs, [:status, :reviewed_by_member_id, :review_note])
    |> validate_inclusion(:status, ~w(approved rejected canceled))
    |> put_change(:reviewed_at, DateTime.utc_now())
  end

  defp validate_date_order(changeset) do
    start_at = get_field(changeset, :start_at)
    end_at = get_field(changeset, :end_at)

    if start_at && end_at && DateTime.compare(start_at, end_at) == :gt do
      add_error(changeset, :end_at, "must be after start date")
    else
      changeset
    end
  end
end
