defmodule Mokaid.Auth.Token do
  @moduledoc """
  Dev/local session tokens signed with the endpoint secret.
  Production uses Cognito JWTs validated by `Mokaid.Auth.Cognito`.
  """

  @salt "mokaid user auth"
  @max_age 60 * 60 * 24 * 7

  def sign(user_id) do
    Phoenix.Token.sign(MokaidWeb.Endpoint, @salt, user_id)
  end

  def verify(token) do
    Phoenix.Token.verify(MokaidWeb.Endpoint, @salt, token, max_age: @max_age)
  end
end
