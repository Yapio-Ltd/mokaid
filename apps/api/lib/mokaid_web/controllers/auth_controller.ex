defmodule MokaidWeb.AuthController do
  use MokaidWeb, :controller

  alias Mokaid.Accounts
  alias Mokaid.Auth.Token
  alias Mokaid.Workspaces
  alias MokaidWeb.JSON, as: Serializer

  def login(conn, %{"email" => email, "password" => password}) do
    with {:ok, user} <- Accounts.authenticate_by_password(email, password) do
      json(conn, %{
        token: Token.sign(user.id),
        user: Serializer.user(user)
      })
    end
  end

  def login(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "bad_request", message: "email and password are required"}})
  end

  def logout(conn, _params) do
    json(conn, %{ok: true})
  end

  @doc """
  Self-serve registration (dev fallback auth mode only — production signups
  go through Cognito). Creates the user, their first workspace and returns
  a session token so the onboarding can start immediately.
  """
  def register(
        conn,
        %{"email" => email, "password" => password, "full_name" => full_name} = params
      ) do
    if Application.get_env(:mokaid, :auth)[:mode] == :dev_fallback do
      workspace_name =
        case String.trim(params["workspace_name"] || "") do
          "" -> "#{full_name |> String.split() |> List.first()}'s Workspace"
          name -> name
        end

      with {:ok, user} <-
             Accounts.register_user(%{
               "email" => email,
               "password" => password,
               "full_name" => full_name
             }),
           {:ok, workspace} <-
             Workspaces.create_workspace(
               %{"name" => workspace_name, "slug" => generate_slug(workspace_name)},
               user
             ) do
        conn
        |> put_status(:created)
        |> json(%{
          token: Token.sign(user.id),
          user: Serializer.user(user),
          workspace: Serializer.workspace(workspace)
        })
      end
    else
      {:error, :registration_disabled}
    end
  end

  def register(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: %{code: "bad_request", message: "email, password and full_name are required"}
    })
  end

  defp generate_slug(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "#{base}-#{suffix}"
  end

  def me(conn, _params) do
    user = current_user(conn)
    workspaces = Workspaces.list_workspaces_with_role(user.id)

    json(conn, %{
      user: Serializer.user(user),
      workspaces:
        Enum.map(workspaces, fn {workspace, role_name} ->
          workspace |> Serializer.workspace() |> Map.put(:role_name, role_name)
        end)
    })
  end
end
