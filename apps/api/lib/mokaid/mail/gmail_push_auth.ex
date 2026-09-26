defmodule Mokaid.Mail.GmailPushAuth do
  @moduledoc "Verifies Google's OIDC signature and the configured Pub/Sub push identity."

  @jwks_url "https://www.googleapis.com/oauth2/v3/certs"
  @cache_key {__MODULE__, :keys}

  def verify("Bearer " <> token) when byte_size(token) in 1..8192 do
    config = Application.get_env(:mokaid, :gmail_pubsub, [])
    now = System.system_time(:second)

    with audience when is_binary(audience) and audience != "" <- config[:audience],
         email when is_binary(email) and email != "" <- config[:service_account],
         {:ok, %{"alg" => "RS256", "kid" => kid}} <- Joken.peek_header(token),
         {:ok, keys} <- signing_keys(now),
         %{} = key <- Enum.find(keys, &(&1["kid"] == kid and &1["kty"] == "RSA")),
         {:ok, claims} <- Joken.verify(token, Joken.Signer.create("RS256", key)),
         true <- claims["iss"] in ["accounts.google.com", "https://accounts.google.com"],
         true <- claims["aud"] == audience and claims["email"] == email,
         true <- claims["email_verified"] == true,
         exp when is_integer(exp) and exp > now <- claims["exp"],
         iat when is_integer(iat) and iat <= now + 60 <- claims["iat"] do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  end

  def verify(_), do: {:error, :unauthorized}

  defp signing_keys(now) do
    case :persistent_term.get(@cache_key, nil) do
      {expires, keys} when expires > now -> {:ok, keys}
      _ -> fetch_keys(now)
    end
  end

  defp fetch_keys(now) do
    options = Application.get_env(:mokaid, :gmail_push_http_options, [])

    case Req.get(Keyword.merge([url: @jwks_url, receive_timeout: 5_000, retry: false], options)) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        :persistent_term.put(@cache_key, {now + 300, keys})
        {:ok, keys}

      _ ->
        {:error, :unavailable}
    end
  end
end
