defmodule Mokaid.Auth.Google do
  @moduledoc """
  Google OAuth2 for **identity** (sign in / sign up).

  Separate from `Mokaid.Integrations.GoogleOAuth` (Drive/Gmail/…).
  Uses the same `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`, with redirect
  URIs under `/auth/google/callback`.
  """

  require Logger

  @authorize_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @userinfo_endpoint "https://www.googleapis.com/oauth2/v2/userinfo"
  @state_salt "auth_google_oauth"
  @state_max_age 600
  @scopes ~w(openid email profile)

  def configured? do
    config = oauth_config()

    is_binary(config[:client_id]) and config[:client_id] != "" and
      is_binary(config[:client_secret]) and config[:client_secret] != ""
  end

  @doc "Builds the Google consent URL for login/signup."
  def authorize_url(redirect_uri, opts \\ []) do
    intent = Keyword.get(opts, :intent, "login")
    challenge = Keyword.get(opts, :code_challenge)

    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri),
         true <- intent in ["login", "signup"],
         true <- valid_challenge?(challenge) do
      state =
        Phoenix.Token.sign(MokaidWeb.Endpoint, @state_salt, %{
          intent: intent,
          redirect_uri: redirect_uri,
          code_challenge: challenge,
          nonce: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        })

      query =
        URI.encode_query(%{
          "client_id" => oauth_config()[:client_id],
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => Enum.join(@scopes, " "),
          "state" => state,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "access_type" => "online",
          "prompt" => "select_account",
          "include_granted_scopes" => "true"
        })

      {:ok, "#{@authorize_endpoint}?#{query}"}
    else
      false -> {:error, :invalid_state}
      other -> other
    end
  end

  @doc """
  Exchanges the authorization code and returns a normalized profile map:

      %{sub: ..., email: ..., name: ..., picture: ...}
  """
  def exchange_code(code, state, redirect_uri, verifier)
      when is_binary(code) and byte_size(code) in 1..4096 and is_binary(state) and
             byte_size(state) <= 4096 do
    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri),
         {:ok, %{intent: intent, redirect_uri: ^redirect_uri, code_challenge: challenge}} <-
           Phoenix.Token.verify(MokaidWeb.Endpoint, @state_salt, state, max_age: @state_max_age),
         true <- valid_verifier?(verifier, challenge),
         {:ok, tokens} <- request_tokens(code, redirect_uri, verifier),
         {:ok, profile} <- fetch_profile(tokens),
         true <- profile.email_verified do
      {:ok, Map.put(profile, :intent, intent)}
    else
      {:error, :invalid} -> {:error, :invalid_state}
      {:error, :expired} -> {:error, :invalid_state}
      {:ok, _} -> {:error, :invalid_state}
      false -> {:error, :invalid_credentials}
      other -> other
    end
  end

  def exchange_code(_, _, _, _), do: {:error, :invalid_state}

  defp valid_challenge?(challenge) do
    is_binary(challenge) and byte_size(challenge) == 43 and
      Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, challenge)
  end

  defp valid_verifier?(verifier, challenge) do
    is_binary(verifier) and byte_size(verifier) in 43..128 and
      Regex.match?(~r/\A[A-Za-z0-9._~-]{43,128}\z/, verifier) and
      valid_challenge?(challenge) and
      Plug.Crypto.secure_compare(
        Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        challenge
      )
  end

  defp request_tokens(code, redirect_uri, verifier) do
    config = oauth_config()

    case Req.post(http_client(),
           url: @token_endpoint,
           form: [
             code: code,
             code_verifier: verifier,
             client_id: config[:client_id],
             client_secret: config[:client_secret],
             redirect_uri: redirect_uri,
             grant_type: "authorization_code"
           ],
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => _} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Google identity token exchange refused status=#{status}")
        {:error, {:token_exchange_failed, status, :provider_error}}

      {:error, _exception} ->
        Logger.warning("Google identity token exchange network failure")
        {:error, {:token_exchange_failed, :network, :unavailable}}
    end
  end

  defp fetch_profile(%{"access_token" => access_token} = tokens) do
    case Req.get(http_client(),
           url: @userinfo_endpoint,
           headers: [{"authorization", "Bearer #{access_token}"}]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"email" => email, "id" => sub} = body}}
      when is_binary(email) and email != "" and is_binary(sub) and sub != "" ->
        {:ok,
         %{
           sub: sub,
           email: String.downcase(email),
           name: body["name"] || body["given_name"] || email,
           picture: body["picture"],
           email_verified: body["verified_email"] == true or body["email_verified"] == true,
           id_token: tokens["id_token"]
         }}

      {:ok, %Req.Response{status: 200, body: body}} ->
        # Some Google responses use `sub` instead of `id`.
        case body do
          %{"email" => email, "sub" => sub}
          when is_binary(email) and email != "" and is_binary(sub) and sub != "" ->
            {:ok,
             %{
               sub: sub,
               email: String.downcase(email),
               name: body["name"] || body["given_name"] || email,
               picture: body["picture"],
               email_verified: body["verified_email"] == true or body["email_verified"] == true,
               id_token: tokens["id_token"]
             }}

          _ ->
            {:error, :profile_incomplete}
        end

      _ ->
        {:error, :profile_fetch_failed}
    end
  end

  defp validate_redirect_uri(redirect_uri) do
    allowed = auth_redirect_uris()

    if redirect_uri in allowed do
      :ok
    else
      {:error, :invalid_redirect_uri}
    end
  end

  defp auth_redirect_uris do
    Application.get_env(:mokaid, :google_auth, [])
    |> Keyword.get(:redirect_uris, [])
  end

  defp ensure_configured do
    if configured?(), do: :ok, else: {:error, :oauth_not_configured}
  end

  defp http_client do
    Req.new(Application.get_env(:mokaid, :google_identity_http_options, []))
  end

  defp oauth_config, do: Application.get_env(:mokaid, :google_oauth, [])
end
