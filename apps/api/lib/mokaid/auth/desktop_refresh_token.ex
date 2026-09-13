defmodule Mokaid.Auth.DesktopRefreshToken do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "desktop_refresh_tokens" do
    belongs_to :session, Mokaid.Auth.DesktopSession
    field :token_hash, :binary, redact: true
    field :used_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
