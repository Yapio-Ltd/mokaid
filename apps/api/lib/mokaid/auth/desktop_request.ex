defmodule Mokaid.Auth.DesktopRequest do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "desktop_auth_requests" do
    field :code_challenge, :string, redact: true
    field :redirect_uri, :string
    field :state, :string, redact: true
    field :code_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :approved_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    belongs_to :user, Mokaid.Accounts.User
    timestamps(type: :utc_datetime_usec)
  end
end
