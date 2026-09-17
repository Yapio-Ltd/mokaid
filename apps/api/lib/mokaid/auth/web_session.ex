defmodule Mokaid.Auth.WebSession do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "web_sessions" do
    belongs_to :user, Mokaid.Accounts.User
    field :token_hash, :binary, redact: true
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
