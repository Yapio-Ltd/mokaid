defmodule Mokaid.Accounts do
  @moduledoc "Users, authentication and sessions."

  import Ecto.Query

  alias Mokaid.Accounts.User
  alias Mokaid.Repo

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  def get_user_by_cognito_sub(sub) when is_binary(sub) do
    Repo.get_by(User, cognito_sub: sub)
  end

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Authenticates a user with email/password (dev fallback only — production
  authentication goes through Cognito JWTs).
  """
  def authenticate_by_password(email, password) do
    user = get_user_by_email(email)

    if user && User.valid_password?(user, password) do
      {:ok, touch_login(user)}
    else
      {:error, :invalid_credentials}
    end
  end

  @doc """
  Finds or provisions the internal user mapped to a Cognito subject.
  Called after successful Cognito JWT validation.
  """
  def upsert_from_cognito(%{sub: sub, email: email} = claims) do
    case get_user_by_cognito_sub(sub) do
      %User{} = user ->
        {:ok, touch_login(user)}

      nil ->
        case get_user_by_email(email) do
          %User{} = user ->
            user
            |> Ecto.Changeset.change(cognito_sub: sub)
            |> Repo.update()

          nil ->
            register_user(%{
              email: email,
              full_name: claims[:name] || email,
              cognito_sub: sub
            })
        end
    end
  end

  defp touch_login(user) do
    user
    |> Ecto.Changeset.change(last_login_at: DateTime.utc_now())
    |> Repo.update!()
  end

  def list_users_by_ids(ids) do
    Repo.all(from u in User, where: u.id in ^ids)
  end
end
