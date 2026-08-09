defmodule Mokaid.Integrations.MicrosoftOAuth do
  @moduledoc """
  Microsoft identity platform OAuth2 for workspace integrations (Outlook mail).

  Uses the `common` endpoint so both organizational (Entra ID) and personal
  Microsoft accounts can connect. Credentials come from `MICROSOFT_CLIENT_ID` /
  `MICROSOFT_CLIENT_SECRET` (AWS Secrets Manager in deployed environments).
  """

  @token_endpoint_template "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"
  @authorize_endpoint_template "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize"
  @graph_me_endpoint "https://graph.microsoft.com/v1.0/me"
  @state_salt "integrations_microsoft_oauth"
  @state_max_age 600

  @scopes [
    "openid",
    "email",
    "profile",
    "offline_access",
    "User.Read",
    "Mail.Read",
    "Mail.Send"
  ]

  @provider_key "outlook"

  def provider_key, do: @provider_key

  def microsoft_provider?(key) when is_binary(key), do: key == @provider_key
  def microsoft_provider?(_), do: false

  def scopes, do: @scopes

  def configured? do
    config = config()

    is_binary(config[:client_id]) and config[:client_id] != "" and
      is_binary(config[:client_secret]) and config[:client_secret] != ""
  end

  def authorize_url(workspace_id, member_id, redirect_uri) do
    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri) do
      state =
        Phoenix.Token.sign(MokaidWeb.Endpoint, @state_salt, %{
          workspace_id: workspace_id,
          member_id: member_id
        })

      query =
        URI.encode_query(%{
          "client_id" => config()[:client_id],
          "redirect_uri" => redirect_uri,
          "response_type" => "code",
          "response_mode" => "query",
          "scope" => Enum.join(@scopes, " "),
          "state" => state,
          "prompt" => "select_account"
        })

      {:ok, "#{authorize_endpoint()}?#{query}"}
    end
  end

  def exchange_code(code, state, redirect_uri) do
    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri),
         {:ok, %{workspace_id: workspace_id, member_id: member_id}} <-
           Phoenix.Token.verify(MokaidWeb.Endpoint, @state_salt, state, max_age: @state_max_age),
         {:ok, tokens} <- request_tokens(code, redirect_uri) do
      account = fetch_account_email(tokens["access_token"])

      {:ok,
       %{
         workspace_id: workspace_id,
         member_id: member_id,
         provider_key: @provider_key,
         credentials: credentials_from_tokens(tokens),
         account: account
       }}
    else
      {:error, :invalid} -> {:error, :invalid_state}
      {:error, :expired} -> {:error, :invalid_state}
      other -> other
    end
  end

  @doc "Exchanges a refresh token for fresh credentials."
  def refresh_tokens(refresh_token) do
    with :ok <- ensure_configured() do
      response =
        Req.post(token_endpoint(),
          form: [
            client_id: config()[:client_id],
            client_secret: config()[:client_secret],
            refresh_token: refresh_token,
            grant_type: "refresh_token",
            scope: Enum.join(@scopes, " ")
          ]
        )

      case response do
        {:ok, %Req.Response{status: 200, body: %{"access_token" => _} = body}} ->
          {:ok, credentials_from_tokens(body, refresh_token)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:token_refresh_failed, status, inspect(body)}}

        {:error, exception} ->
          {:error, {:token_refresh_failed, :network, Exception.message(exception)}}
      end
    end
  end

  defp credentials_from_tokens(tokens, fallback_refresh_token \\ nil) do
    %{
      "access_token" => tokens["access_token"],
      "refresh_token" => tokens["refresh_token"] || fallback_refresh_token,
      "token_type" => tokens["token_type"] || "Bearer",
      "scope" => tokens["scope"],
      "expires_at" =>
        DateTime.utc_now()
        |> DateTime.add(tokens["expires_in"] || 3600, :second)
        |> DateTime.to_iso8601()
    }
  end

  defp request_tokens(code, redirect_uri) do
    config = config()

    response =
      Req.post(token_endpoint(),
        form: [
          code: code,
          client_id: config[:client_id],
          client_secret: config[:client_secret],
          redirect_uri: redirect_uri,
          grant_type: "authorization_code",
          scope: Enum.join(@scopes, " ")
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
    case Req.get(@graph_me_endpoint, headers: [{"authorization", "Bearer #{access_token}"}]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        body["mail"] || body["userPrincipalName"]

      _ ->
        nil
    end
  end

  defp validate_redirect_uri(redirect_uri) do
    if redirect_uri in (config()[:redirect_uris] || []) do
      :ok
    else
      {:error, :invalid_redirect_uri}
    end
  end

  defp ensure_configured do
    if configured?(), do: :ok, else: {:error, :oauth_not_configured}
  end

  defp tenant, do: config()[:tenant] || "common"

  defp authorize_endpoint,
    do: String.replace(@authorize_endpoint_template, "{tenant}", tenant())

  defp token_endpoint, do: String.replace(@token_endpoint_template, "{tenant}", tenant())

  defp config, do: Application.get_env(:mokaid, :microsoft_oauth, [])
end
