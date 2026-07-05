defmodule Mokaid.Auth.Cognito do
  @moduledoc """
  Validates Amazon Cognito JWT access tokens against the pool's JWKS,
  then maps the `sub` claim to the internal users table.
  """

  use Joken.Config

  def issuer do
    config = Application.fetch_env!(:mokaid, :auth)

    "https://cognito-idp.#{config[:cognito_region]}.amazonaws.com/#{config[:cognito_user_pool_id]}"
  end

  def jwks_url, do: issuer() <> "/.well-known/jwks.json"

  @impl Joken.Config
  def token_config do
    config = Application.fetch_env!(:mokaid, :auth)

    default_claims(skip: [:aud, :iss])
    |> add_claim("iss", nil, &(&1 == issuer()))
    |> add_claim("client_id", nil, &(&1 == config[:cognito_client_id]))
    |> add_claim("token_use", nil, &(&1 == "access"))
  end

  @doc "Verifies a Cognito JWT and returns `{:ok, %{sub: ..., email: ...}}`."
  def verify_token(token) do
    with {:ok, claims} <-
           verify_and_validate(token, Joken.Signer.create("RS256", fetch_signing_key(token))) do
      {:ok, %{sub: claims["sub"], email: claims["email"] || claims["username"]}}
    end
  end

  defp fetch_signing_key(token) do
    with {:ok, %{"kid" => kid}} <- Joken.peek_header(token),
         {:ok, %{status: 200, body: %{"keys" => keys}}} <- Req.get(url: jwks_url()),
         %{} = jwk <- Enum.find(keys, &(&1["kid"] == kid)) do
      jwk
    else
      _ -> %{}
    end
  end
end
