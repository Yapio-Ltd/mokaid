defmodule Mokaid.Members.MemberInvite do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "member_invites" do
    belongs_to :workspace, Mokaid.Workspaces.Workspace
    belongs_to :role, Mokaid.Members.Role
    belongs_to :team, Mokaid.Members.Team
    belongs_to :invited_by_member, Mokaid.Members.Member

    field :email, :string
    field :token, :string
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:workspace_id, :email, :role_id, :team_id, :invited_by_member_id])
    |> validate_required([:workspace_id, :email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> put_change(:token, generate_token())
    |> put_change(:expires_at, DateTime.add(DateTime.utc_now(), 7, :day))
    |> unique_constraint(:token)
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
