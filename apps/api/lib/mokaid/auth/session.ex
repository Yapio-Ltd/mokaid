defmodule Mokaid.Auth.Session do
  @moduledoc "Shared live-user verification for HTTP and Phoenix sockets."
  alias Mokaid.Accounts
  alias Mokaid.Accounts.User
  alias Mokaid.Auth.Desktop

  def authenticate(token) when is_binary(token) do
    result =
      if Desktop.access_token?(token), do: Desktop.verify_access(token), else: legacy(token)

    with {:ok, user, metadata} <- result,
         true <- User.active?(user) do
      {:ok, user, metadata}
    else
      false -> {:error, :inactive}
      error -> error
    end
  end

  def authenticate(_), do: {:error, :unauthorized}

  defp legacy(token) do
    case Application.fetch_env!(:mokaid, :auth)[:mode] do
      :cognito ->
        with {:ok, claims} <- Mokaid.Auth.Cognito.verify_token(token),
             {:ok, user} <- Accounts.upsert_from_cognito(claims),
             do: {:ok, user, %{}}

      :dev_fallback ->
        with {:ok, id} <- Mokaid.Auth.Token.verify(token),
             {:ok, id} <- Ecto.UUID.cast(id),
             %User{} = user <- Accounts.get_user(id) do
          {:ok, user, %{}}
        else
          _ -> {:error, :unauthorized}
        end
    end
  end
end
