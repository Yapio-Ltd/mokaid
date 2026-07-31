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
  Updates the password for an email/password account after verifying the
  current password. OAuth-only accounts (no local hash) cannot change it here.
  """
  def change_password(%User{} = user, attrs) do
    if User.has_password?(user) do
      user
      |> User.password_changeset(attrs)
      |> Repo.update()
    else
      {:error, :oauth_only}
    end
  end

  def has_password?(%User{} = user), do: User.has_password?(user)

  @doc """
  Signs in or registers a user from a verified Google profile.
  Returns `{:ok, user, :created | :existing}`. New users get a workspace.
  """
  def login_or_register_with_google(%{sub: sub, email: email} = profile)
      when is_binary(sub) and is_binary(email) do
    google_key = google_identity_key(sub)
    name = profile[:name] || profile["name"] || email
    picture = profile[:picture] || profile["picture"]

    Repo.transaction(fn ->
      case find_google_user(google_key, email) do
        nil ->
          workspace_name = default_workspace_name(name)

          with {:ok, user} <-
                 register_user(%{
                   "email" => email,
                   "full_name" => name,
                   "avatar_url" => picture,
                   "cognito_sub" => google_key
                 }),
               {:ok, workspace} <-
                 Mokaid.Workspaces.create_workspace(
                   %{"name" => workspace_name},
                   user
                 ) do
            {touch_login(user), :created, workspace}
          else
            {:error, changeset} -> Repo.rollback(changeset)
          end

        user ->
          user =
            user
            |> Ecto.Changeset.change(
              cognito_sub: user.cognito_sub || google_key,
              avatar_url: user.avatar_url || picture,
              full_name: if(user.full_name in [nil, ""], do: name, else: user.full_name)
            )
            |> Repo.update!()
            |> touch_login()

          {user, :existing, nil}
      end
    end)
    |> case do
      {:ok, {user, :created, workspace}} -> {:ok, user, :created, workspace}
      {:ok, {user, :existing, _}} -> {:ok, user, :existing, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def login_or_register_with_google(_), do: {:error, :profile_incomplete}

  def google_identity_key(sub) when is_binary(sub), do: "google:#{sub}"

  defp find_google_user(google_key, email) do
    get_user_by_cognito_sub(google_key) || get_user_by_email(email)
  end

  defp default_workspace_name(full_name) when is_binary(full_name) do
    first = full_name |> String.split() |> List.first() || "My"
    "#{first}'s Workspace"
  end

  defp default_workspace_name(_), do: "My Workspace"

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
