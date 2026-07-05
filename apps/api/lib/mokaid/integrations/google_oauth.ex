defmodule Mokaid.Integrations.GoogleOAuth do
  @moduledoc """
  Google OAuth2 for workspace integrations (Drive, Gmail, Calendar, Docs, Sheets…).

  One consent flow stores shared credentials on every Google integration provider
  for the workspace. Credentials come from `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`
  (AWS Secrets Manager in deployed environments).
  """

  @authorize_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @userinfo_endpoint "https://www.googleapis.com/oauth2/v2/userinfo"
  @state_salt "integrations_google_oauth"
  @state_max_age 600

  @scopes [
    "openid",
    "email",
    "profile",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/meetings.space.created"
  ]

  @google_provider_keys ~w(
    google_drive
    gmail
    google_calendar
    google_docs
    google_sheets
    google_meet
  )

  def google_provider_keys, do: @google_provider_keys

  def google_provider?(key) when is_binary(key), do: key in @google_provider_keys
  def google_provider?(_), do: false

  def configured? do
    config = config()
    is_binary(config[:client_id]) and config[:client_id] != "" and
      is_binary(config[:client_secret]) and config[:client_secret] != ""
  end

  def authorize_url(workspace_id, member_id, redirect_uri, provider_key \\ "google_drive") do
    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri),
         :ok <- validate_provider_key(provider_key) do
      state =
        Phoenix.Token.sign(MokaidWeb.Endpoint, @state_salt, %{
          workspace_id: workspace_id,
          member_id: member_id,
          provider_key: provider_key
        })

      query =
        URI.encode_query(%{
          "client_id" => config()[:client_id],
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "scope" => Enum.join(@scopes, " "),
          "state" => state,
          "access_type" => "offline",
          "prompt" => "consent",
          "include_granted_scopes" => "true"
        })

      {:ok, "#{@authorize_endpoint}?#{query}"}
    end
  end

  def exchange_code(code, state, redirect_uri) do
    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri),
         {:ok,
          %{workspace_id: workspace_id, member_id: member_id, provider_key: provider_key}} <-
           Phoenix.Token.verify(MokaidWeb.Endpoint, @state_salt, state, max_age: @state_max_age),
         {:ok, tokens} <- request_tokens(code, redirect_uri) do
      account = fetch_account_email(tokens["access_token"])

      credentials = %{
        "access_token" => tokens["access_token"],
        "refresh_token" => tokens["refresh_token"],
        "token_type" => tokens["token_type"] || "Bearer",
        "scope" => tokens["scope"],
        "expires_at" =>
          DateTime.utc_now()
          |> DateTime.add(tokens["expires_in"] || 3600, :second)
          |> DateTime.to_iso8601()
      }

      {:ok,
       %{
         workspace_id: workspace_id,
         member_id: member_id,
         provider_key: provider_key,
         credentials: credentials,
         account: account
       }}
    else
      {:error, :invalid} -> {:error, :invalid_state}
      {:error, :expired} -> {:error, :invalid_state}
      other -> other
    end
  end

  defp request_tokens(code, redirect_uri) do
    config = config()

    response =
      Req.post(@token_endpoint,
        form: [
          code: code,
          client_id: config[:client_id],
          client_secret: config[:client_secret],
          redirect_uri: redirect_uri,
          grant_type: "authorization_code"
        ]
      )

    case response do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => _} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:token_exchange_failed, status, inspect(body)}}

      {:error, exception} ->
        {:error, {:token_exchange_failed, :network, Exception.message(exception)}}
    end
  end

  defp fetch_account_email(access_token) do
    case Req.get(@userinfo_endpoint, headers: [{"authorization", "Bearer #{access_token}"}]) do
      {:ok, %Req.Response{status: 200, body: %{"email" => email}}} -> email
      _ -> nil
    end
  end

  defp validate_redirect_uri(redirect_uri) do
    if redirect_uri in (config()[:redirect_uris] || []) do
      :ok
    else
      {:error, :invalid_redirect_uri}
    end
  end

  defp validate_provider_key(key) do
    if google_provider?(key), do: :ok, else: {:error, :invalid_provider}
  end

  defp ensure_configured do
    if configured?(), do: :ok, else: {:error, :oauth_not_configured}
  end

  defp config, do: Application.get_env(:mokaid, :google_oauth, [])
end
