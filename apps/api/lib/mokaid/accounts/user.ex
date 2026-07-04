defmodule Mokaid.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "users" do
    field :email, :string
    field :cognito_sub, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :full_name, :string
    field :avatar_url, :string
    field :locale, :string, default: "en"
    field :timezone, :string, default: "UTC"
    field :status, :string, default: "active"
    field :last_login_at, :utc_datetime_usec
    field :mfa_enabled, :boolean, default: false

    has_many :memberships, Mokaid.Members.Member

    timestamps()
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :full_name, :password, :avatar_url, :locale, :timezone, :cognito_sub])
    |> validate_required([:email, :full_name])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> unique_constraint(:email)
    |> unique_constraint(:cognito_sub)
    |> maybe_hash_password()
  end

  def profile_changeset(user, attrs) do
    cast(user, attrs, [:full_name, :avatar_url, :locale, :timezone])
  end

  defp maybe_hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> validate_length(:password, min: 10, max: 100)
        |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end

  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
