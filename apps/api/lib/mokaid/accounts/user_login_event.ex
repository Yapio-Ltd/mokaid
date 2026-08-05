defmodule Mokaid.Accounts.UserLoginEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "user_login_events" do
    belongs_to :user, Mokaid.Accounts.User

    field :ip_address, :string
    field :user_agent, :string
    field :auth_method, :string, default: "password"
    field :success, :boolean, default: true
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    timestamps(updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :user_id,
      :ip_address,
      :user_agent,
      :auth_method,
      :success,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:user_id, :auth_method, :occurred_at])
  end
end
