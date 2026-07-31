defmodule Mokaid.Auth.Google do
  @moduledoc """
  Google OAuth2 for **identity** (sign in / sign up).

  Separate from `Mokaid.Integrations.GoogleOAuth` (Drive/Gmail/…).
  Uses the same `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`, with redirect
  URIs under `/auth/google/callback`.
  """

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

    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri) do
      state =
        Phoenix.Token.sign(MokaidWeb.Endpoint, @state_salt, %{
          intent: intent,
          redirect_uri: redirect_uri
        })

      query =
        URI.encode_query(%{
          "client_id" => oauth_config()[:client_id],
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => Enum.join(@scopes, " "),
          "state" => state,
          "access_type" => "online",
          "prompt" => "select_account",
          "include_granted_scopes" => "true"
        })

      {:ok, "#{@authorize_endpoint}?#{query}"}
    end
  end

  @doc """
  Exchanges the authorization code and returns a normalized profile map:

      %{sub: ..., email: ..., name: ..., picture: ...}
  """
  def exchange_code(code, state, redirect_uri) do
    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri),
         {:ok, %{intent: intent}} <-
           Phoenix.Token.verify(MokaidWeb.Endpoint, @state_salt, state, max_age: @state_max_age),
         {:ok, tokens} <- request_tokens(code, redirect_uri),
         {:ok, profile} <- fetch_profile(tokens) do
      {:ok, Map.put(profile, :intent, intent)}
    else
      {:error, :invalid} -> {:error, :invalid_state}
      {:error, :expired} -> {:error, :invalid_state}
      other -> other
    end
  end

  defp request_tokens(code, redirect_uri) do
    config = oauth_config()

    case Req.post(@token_endpoint,
           form: [
             code: code,
             client_id: config[:client_id],
             client_secret: config[:client_secret],
             redirect_uri: redirect_uri,
             grant_type: "authorization_code"
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => _} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:token_exchange_failed, status, inspect(body)}}

      {:error, exception} ->
        {:error, {:token_exchange_failed, :network, Exception.message(exception)}}
    end
  end

  defp fetch_profile(%{"access_token" => access_token} = tokens) do
    case Req.get(@userinfo_endpoint, headers: [{"authorization", "Bearer #{access_token}"}]) do
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

  defp oauth_config, do: Application.get_env(:mokaid, :google_oauth, [])
end
