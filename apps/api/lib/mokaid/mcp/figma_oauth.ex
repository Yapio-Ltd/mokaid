defmodule Mokaid.MCP.FigmaOAuth do
  @moduledoc """
  Figma OAuth2 flow for the MCP Hub.

  `authorize_url/2` builds the Figma consent URL with a signed `state`
  (workspace + member, 10 min TTL). `exchange_code/2` trades the callback
  code for tokens and resolves the connected account. Credentials come from
  `FIGMA_CLIENT_ID` / `FIGMA_CLIENT_SECRET` (AWS Secrets Manager in deployed
  environments).
  """

  @authorize_endpoint "https://www.figma.com/oauth"
  @token_endpoint "https://api.figma.com/v1/oauth/token"
  @me_endpoint "https://api.figma.com/v1/me"
  @scope "files:read"
  @state_salt "mcp_figma_oauth"
  @state_max_age 600

  def configured? do
    config = config()
    is_binary(config[:client_id]) and is_binary(config[:client_secret])
  end

  @doc "Builds the authorization URL. Returns {:ok, url} or {:error, reason}."
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
          "scope" => @scope,
          "state" => state,
          "response_type" => "code"
        })

      {:ok, "#{@authorize_endpoint}?#{query}"}
    end
  end

  @doc """
  Verifies the signed state and exchanges the code for tokens.
  Returns `{:ok, %{workspace_id, member_id, credentials, account}}`.
  """
  def exchange_code(code, state, redirect_uri) do
    with :ok <- ensure_configured(),
         :ok <- validate_redirect_uri(redirect_uri),
         {:ok, %{workspace_id: workspace_id, member_id: member_id}} <-
           Phoenix.Token.verify(MokaidWeb.Endpoint, @state_salt, state, max_age: @state_max_age),
         {:ok, tokens} <- request_tokens(code, redirect_uri) do
      account = fetch_account_email(tokens["access_token"])

      credentials = %{
        "access_token" => tokens["access_token"],
        "refresh_token" => tokens["refresh_token"],
        "token_type" => "bearer",
        "expires_at" =>
          DateTime.utc_now()
          |> DateTime.add(tokens["expires_in"] || 3600, :second)
          |> DateTime.to_iso8601()
      }

      {:ok,
       %{
         workspace_id: workspace_id,
         member_id: member_id,
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
    basic = Base.encode64("#{config[:client_id]}:#{config[:client_secret]}")

    response =
      Req.post(@token_endpoint,
        headers: [{"authorization", "Basic #{basic}"}],
        form: [code: code, redirect_uri: redirect_uri, grant_type: "authorization_code"]
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
    case Req.get(@me_endpoint, headers: [{"authorization", "Bearer #{access_token}"}]) do
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

  defp ensure_configured do
    if configured?(), do: :ok, else: {:error, :oauth_not_configured}
  end

  defp config, do: Application.get_env(:mokaid, :figma_oauth, [])
end
