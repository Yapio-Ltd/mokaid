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

  def me(conn, _params) do
    user = current_user(conn)
    workspaces = Workspaces.list_workspaces_for_user(user.id)

    json(conn, %{
      user: Serializer.user(user),
      workspaces: Enum.map(workspaces, &Serializer.workspace/1)
    })
  end
end
