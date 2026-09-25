defmodule Mokaid.Integrations.GoogleOAuth do
  @moduledoc "Google consent scoped to the requested integration, with encrypted PKCE state."

  @authorize_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @userinfo_endpoint "https://www.googleapis.com/oauth2/v2/userinfo"
  @state_salt "integrations_google_oauth_v2"
  @state_max_age 600
  @provider_scopes %{
    "gmail" => ["https://www.googleapis.com/auth/gmail.modify"],
    "google_drive" => ["https://www.googleapis.com/auth/drive"],
    "google_calendar" => ["https://www.googleapis.com/auth/calendar"],
    "google_docs" => ["https://www.googleapis.com/auth/documents"],
    "google_sheets" => ["https://www.googleapis.com/auth/spreadsheets"],
    "google_meet" => ["https://www.googleapis.com/auth/meetings.space.created"]
  }

  def google_provider_keys, do: Map.keys(@provider_scopes)
  def google_provider?(key), do: Map.has_key?(@provider_scopes, key)
  def scopes(key), do: ["openid", "email"] ++ Map.get(@provider_scopes, key, [])

  def configured? do
    Enum.all?([:client_id, :client_secret], fn key ->
      is_binary(config()[key]) and String.trim(config()[key]) != ""
    end)
  end

  def authorize_url(
        workspace_id,
        member_id,
        redirect_uri,
        provider_key \\ "google_drive",
        opts \\ []
      ) do
    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri),
         true <- google_provider?(provider_key) do
      verifier = Base.url_encode64(:crypto.strong_rand_bytes(48), padding: false)
      challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

      # Encryption keeps the verifier secret even though state travels through the browser.
      state =
        Phoenix.Token.encrypt(MokaidWeb.Endpoint, @state_salt, %{
          workspace_id: workspace_id,
          member_id: member_id,
          provider_key: provider_key,
          redirect_uri: redirect_uri,
          code_verifier: verifier,
          flow_id: Keyword.get(opts, :flow_id)
        })

      query =
        URI.encode_query(%{
          "client_id" => config()[:client_id],
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => Enum.join(scopes(provider_key), " "),
          "state" => state,
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "access_type" => "offline",
          "prompt" => "consent select_account",
          "include_granted_scopes" => "false"
        })

      {:ok, "#{@authorize_endpoint}?#{query}"}
    else
      false -> {:error, :invalid_provider}
      other -> other
    end
  end

  def verify_state(state, redirect_uri) when is_binary(state) and byte_size(state) <= 8192 do
    with :ok <- validate_redirect_uri(redirect_uri),
         {:ok, %{redirect_uri: ^redirect_uri, provider_key: provider} = result} <-
           Phoenix.Token.decrypt(MokaidWeb.Endpoint, @state_salt, state, max_age: @state_max_age),
         true <- google_provider?(provider) do
      {:ok, result}
    else
      _ -> {:error, :invalid_state}
    end
  end

  def verify_state(_, _), do: {:error, :invalid_state}

  # Browser completion must match the initiating member. Desktop completion is
  # authorized by the persisted flow and is performed only by its public callback.
  def exchange_code(code, state, redirect_uri, expected_identity \\ nil)

  def exchange_code(code, state, redirect_uri, expected_identity)
      when is_binary(code) and byte_size(code) in 1..4096 do
    with :ok <- ensure_configured(),
         {:ok, data} <- verify_state(state, redirect_uri),
         :ok <- validate_identity(data, expected_identity),
         {:ok, tokens} <- request_tokens(code, redirect_uri, data.code_verifier),
         :ok <- validate_granted_scopes(tokens, data.provider_key),
         {:ok, account} <- fetch_account_email(tokens["access_token"]) do
      {:ok, Map.merge(data, %{credentials: credentials(tokens), account: account})}
    end
  end

  def exchange_code(_, _, _, _), do: {:error, :invalid_state}

  def refresh_tokens(refresh_token) when is_binary(refresh_token) and refresh_token != "" do
    with :ok <- ensure_configured(),
         {:ok, body} <-
           token_request(
             [
               client_id: config()[:client_id],
               client_secret: config()[:client_secret],
               refresh_token: refresh_token,
               grant_type: "refresh_token"
             ],
             :token_refresh_failed
           ) do
      {:ok, Map.put(credentials(body), "refresh_token", body["refresh_token"] || refresh_token)}
    end
  end

  def refresh_tokens(_), do: {:error, :missing_refresh_token}

  defp credentials(tokens) do
    %{
      "access_token" => tokens["access_token"],
      "refresh_token" => tokens["refresh_token"],
      "token_type" => tokens["token_type"] || "Bearer",
      "scope" => tokens["scope"],
      "expires_at" =>
        DateTime.utc_now()
        |> DateTime.add(tokens["expires_in"] || 3600, :second)
        |> DateTime.to_iso8601()
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp request_tokens(code, redirect_uri, verifier) do
    token_request(
      [
        code: code,
        code_verifier: verifier,
        client_id: config()[:client_id],
        client_secret: config()[:client_secret],
        redirect_uri: redirect_uri,
        grant_type: "authorization_code"
      ],
      :token_exchange_failed
    )
  end

  defp token_request(form, error) do
    case Req.post(http_client(),
           url: @token_endpoint,
           form: form,
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = body}}
      when is_binary(token) and token != "" ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {error, status, :provider_error}}

      {:error, _} ->
        {:error, {error, :network, :unavailable}}
    end
  end

  defp fetch_account_email(access_token) do
    case Req.get(http_client(),
           url: @userinfo_endpoint,
           headers: [{"authorization", "Bearer #{access_token}"}],
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %Req.Response{status: 200, body: %{"email" => email} = body}}
      when is_binary(email) and email != "" ->
        if body["verified_email"] == true or body["email_verified"] == true,
          do: {:ok, email |> String.trim() |> String.downcase()},
          else: {:error, :unverified_account}

      _ ->
        {:error, :account_fetch_failed}
    end
  end

  defp validate_granted_scopes(%{"scope" => granted}, key) when is_binary(granted) do
    granted = String.split(granted)

    if Enum.all?(Map.fetch!(@provider_scopes, key), &(&1 in granted)),
      do: :ok,
      else: {:error, :missing_required_scopes}
  end

  # Google may omit scope when it matches the requested scope (RFC 6749 §5.1).
  defp validate_granted_scopes(_, _), do: :ok

  defp validate_identity(%{workspace_id: workspace, member_id: member}, {workspace, member}),
    do: :ok

  defp validate_identity(%{flow_id: flow_id}, nil) when is_binary(flow_id), do: :ok
  defp validate_identity(_, _), do: {:error, :invalid_state}

  def desktop_redirect_uri,
    do: config()[:desktop_redirect_uri] || "https://mokaid.com/api/mail/oauth/google/callback"

  defp validate_redirect_uri(redirect_uri) do
    allowed = [desktop_redirect_uri() | config()[:redirect_uris] || []]

    if is_binary(redirect_uri) and redirect_uri in allowed,
      do: :ok,
      else: {:error, :invalid_redirect_uri}
  end

  defp ensure_configured, do: if(configured?(), do: :ok, else: {:error, :oauth_not_configured})
  defp http_client, do: Req.new(Application.get_env(:mokaid, :google_oauth_http_options, []))
  defp config, do: Application.get_env(:mokaid, :google_oauth, [])
end
