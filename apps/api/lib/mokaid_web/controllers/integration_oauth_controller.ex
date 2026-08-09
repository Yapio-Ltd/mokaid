defmodule MokaidWeb.IntegrationOAuthController do
  @moduledoc """
  OAuth flows for workspace integrations (Google, GitHub…).
  """

  use MokaidWeb, :controller

  alias Mokaid.Integrations

  alias Mokaid.Integrations.{
    GitHubOAuth,
    GoogleOAuth,
    LinearOAuth,
    MicrosoftOAuth,
    NotionOAuth,
    SlackOAuth
  }

  alias MokaidWeb.JSON, as: Serializer

  def google_start(conn, params) do
    redirect_uri = params["redirect_uri"] || default_google_redirect_uri()
    provider_key = params["provider_key"] || "google_drive"

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, url} <-
           GoogleOAuth.authorize_url(
             workspace_id(conn),
             current_member(conn).id,
             redirect_uri,
             provider_key
           ) do
      json(conn, %{data: %{authorize_url: url}})
    else
      {:error, :oauth_not_configured} ->
        oauth_not_configured(conn, "Google")

      {:error, :invalid_redirect_uri} ->
        invalid_redirect_uri(conn)

      other ->
        other
    end
  end

  def google_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_uri = params["redirect_uri"] || default_google_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, result} <- GoogleOAuth.exchange_code(code, state, redirect_uri),
         :ok <- ensure_same_workspace(conn, result.workspace_id),
         {:ok, connections} <-
           Integrations.connect_google_providers(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ),
         {:ok, _} <-
           Integrations.sync_google_mcp_installations(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ) do
      ensure_mail_account(conn, result, connections, "gmail")

      json(conn, %{
        data: %{
          connections: Enum.map(connections, &Serializer.integration_connection/1),
          connected_account: result.account,
          provider_key: result.provider_key
        }
      })
    else
      {:error, :invalid_state} -> invalid_state(conn)
      {:error, {:token_exchange_failed, _, _}} -> token_exchange_failed(conn, "Google")
      other -> other
    end
  end

  def github_start(conn, params) do
    redirect_uri = params["redirect_uri"] || default_github_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, url} <-
           GitHubOAuth.authorize_url(
             workspace_id(conn),
             current_member(conn).id,
             redirect_uri
           ) do
      json(conn, %{data: %{authorize_url: url}})
    else
      {:error, :oauth_not_configured} ->
        oauth_not_configured(conn, "GitHub")

      other ->
        other
    end
  end

  def github_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_uri = params["redirect_uri"] || default_github_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, result} <- GitHubOAuth.exchange_code(code, state, redirect_uri),
         :ok <- ensure_same_workspace(conn, result.workspace_id),
         {:ok, connection} <-
           Integrations.connect_github_provider(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ),
         {:ok, _} <-
           Integrations.sync_github_mcp_installation(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ) do
      json(conn, %{
        data: %{
          connection: Serializer.integration_connection(connection),
          connected_account: result.account,
          provider_key: GitHubOAuth.provider_key()
        }
      })
    else
      {:error, :invalid_state} -> invalid_state(conn)
      {:error, {:token_exchange_failed, _, _}} -> token_exchange_failed(conn, "GitHub")
      {:error, :forbidden} -> forbidden(conn)
      other -> other
    end
  end

  def linear_start(conn, params) do
    redirect_uri = params["redirect_uri"] || default_linear_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, url} <-
           LinearOAuth.authorize_url(
             workspace_id(conn),
             current_member(conn).id,
             redirect_uri
           ) do
      json(conn, %{data: %{authorize_url: url}})
    else
      {:error, :oauth_not_configured} ->
        oauth_not_configured(conn, "Linear")

      {:error, :invalid_redirect_uri} ->
        invalid_redirect_uri(conn)

      other ->
        other
    end
  end

  def linear_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_uri = params["redirect_uri"] || default_linear_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, result} <- LinearOAuth.exchange_code(code, state, redirect_uri),
         :ok <- ensure_same_workspace(conn, result.workspace_id),
         {:ok, connection} <-
           Integrations.connect_linear_provider(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ),
         {:ok, _} <-
           Integrations.sync_linear_mcp_installation(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ) do
      json(conn, %{
        data: %{
          connection: Serializer.integration_connection(connection),
          connected_account: result.account,
          provider_key: LinearOAuth.provider_key()
        }
      })
    else
      {:error, :invalid_state} -> invalid_state(conn)
      {:error, {:token_exchange_failed, _, _}} -> token_exchange_failed(conn, "Linear")
      {:error, :forbidden} -> forbidden(conn)
      other -> other
    end
  end

  def slack_start(conn, params) do
    redirect_uri = params["redirect_uri"] || default_slack_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, url} <-
           SlackOAuth.authorize_url(
             workspace_id(conn),
             current_member(conn).id,
             redirect_uri
           ) do
      json(conn, %{data: %{authorize_url: url}})
    else
      {:error, :oauth_not_configured} ->
        oauth_not_configured(conn, "Slack")

      {:error, :invalid_redirect_uri} ->
        invalid_redirect_uri(conn)

      other ->
        other
    end
  end

  def slack_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_uri = params["redirect_uri"] || default_slack_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, result} <- SlackOAuth.exchange_code(code, state, redirect_uri),
         :ok <- ensure_same_workspace(conn, result.workspace_id),
         {:ok, connection} <-
           Integrations.connect_slack_provider(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ),
         {:ok, _} <-
           Integrations.sync_slack_mcp_installation(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ) do
      json(conn, %{
        data: %{
          connection: Serializer.integration_connection(connection),
          connected_account: result.account,
          provider_key: SlackOAuth.provider_key()
        }
      })
    else
      {:error, :invalid_state} -> invalid_state(conn)
      {:error, {:token_exchange_failed, _, _}} -> token_exchange_failed(conn, "Slack")
      {:error, :forbidden} -> forbidden(conn)
      other -> other
    end
  end

  def notion_start(conn, params) do
    redirect_uri = params["redirect_uri"] || default_notion_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, url} <-
           NotionOAuth.authorize_url(
             workspace_id(conn),
             current_member(conn).id,
             redirect_uri
           ) do
      json(conn, %{data: %{authorize_url: url}})
    else
      {:error, :oauth_not_configured} ->
        oauth_not_configured(conn, "Notion")

      {:error, :invalid_redirect_uri} ->
        invalid_redirect_uri(conn)

      other ->
        other
    end
  end

  def notion_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_uri = params["redirect_uri"] || default_notion_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, result} <- NotionOAuth.exchange_code(code, state, redirect_uri),
         :ok <- ensure_same_workspace(conn, result.workspace_id),
         {:ok, connection} <-
           Integrations.connect_notion_provider(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ),
         {:ok, _} <-
           Integrations.sync_notion_mcp_installation(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ) do
      json(conn, %{
        data: %{
          connection: Serializer.integration_connection(connection),
          connected_account: result.account,
          provider_key: NotionOAuth.provider_key()
        }
      })
    else
      {:error, :invalid_state} -> invalid_state(conn)
      {:error, {:token_exchange_failed, _, _}} -> token_exchange_failed(conn, "Notion")
      {:error, :forbidden} -> forbidden(conn)
      other -> other
    end
  end

  def microsoft_start(conn, params) do
    redirect_uri = params["redirect_uri"] || default_microsoft_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, url} <-
           MicrosoftOAuth.authorize_url(
             workspace_id(conn),
             current_member(conn).id,
             redirect_uri
           ) do
      json(conn, %{data: %{authorize_url: url}})
    else
      {:error, :oauth_not_configured} ->
        oauth_not_configured(conn, "Microsoft")

      {:error, :invalid_redirect_uri} ->
        invalid_redirect_uri(conn)

      other ->
        other
    end
  end

  def microsoft_callback(conn, %{"code" => code, "state" => state} = params) do
    redirect_uri = params["redirect_uri"] || default_microsoft_redirect_uri()

    with :ok <- Permissions.authorize(current_member(conn), "integrations.connect"),
         {:ok, result} <- MicrosoftOAuth.exchange_code(code, state, redirect_uri),
         :ok <- ensure_same_workspace(conn, result.workspace_id),
         {:ok, connection} <-
           Integrations.connect_microsoft_provider(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ),
         {:ok, _} <-
           Integrations.sync_microsoft_mcp_installation(
             result.workspace_id,
             current_member(conn),
             result.credentials,
             result.account
           ) do
      ensure_mail_account(conn, result, [connection], "microsoft")

      json(conn, %{
        data: %{
          connection: Serializer.integration_connection(connection),
          connected_account: result.account,
          provider_key: MicrosoftOAuth.provider_key()
        }
      })
    else
      {:error, :invalid_state} -> invalid_state(conn)
      {:error, {:token_exchange_failed, _, _}} -> token_exchange_failed(conn, "Microsoft")
      {:error, :forbidden} -> forbidden(conn)
      other -> other
    end
  end

  # Auto-registers the mailbox for sync after a successful email-capable
  # OAuth. Best-effort: failures must never break the OAuth flow itself.
  defp ensure_mail_account(conn, result, connections, provider) do
    mail_provider_key = if provider == "gmail", do: "gmail", else: "outlook"

    connection =
      Enum.find(connections, fn c ->
        loaded = Mokaid.Repo.preload(c, :provider)
        loaded.provider && loaded.provider.key == mail_provider_key
      end) || List.first(connections)

    if is_binary(result.account) and connection != nil do
      case Mokaid.Mail.ensure_oauth_account(
             result.workspace_id,
             current_member(conn),
             provider,
             result.account,
             connection.id
           ) do
        {:ok, account} ->
          %{"mail_account_id" => account.id}
          |> Mokaid.Mail.Workers.SyncWorker.new()
          |> Oban.insert()

        _ ->
          :ok
      end
    end

    :ok
  end

  defp ensure_same_workspace(conn, state_workspace_id) do
    if workspace_id(conn) == state_workspace_id, do: :ok, else: {:error, :forbidden}
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{code: "forbidden", message: "Workspace mismatch"}})
  end

  defp default_google_redirect_uri do
    Application.get_env(:mokaid, :google_oauth, [])
    |> Keyword.get(:redirect_uris, [])
    |> List.first()
  end

  defp default_github_redirect_uri do
    Application.get_env(:mokaid, :github_oauth, [])
    |> Keyword.get(:redirect_uris, [])
    |> List.first()
  end

  defp default_linear_redirect_uri do
    Application.get_env(:mokaid, :linear_oauth, [])
    |> Keyword.get(:redirect_uris, [])
    |> List.first()
  end

  defp default_slack_redirect_uri do
    Application.get_env(:mokaid, :slack_oauth, [])
    |> Keyword.get(:redirect_uris, [])
    |> List.first()
  end

  defp default_notion_redirect_uri do
    Application.get_env(:mokaid, :notion_oauth, [])
    |> Keyword.get(:redirect_uris, [])
    |> List.first()
  end

  defp default_microsoft_redirect_uri do
    Application.get_env(:mokaid, :microsoft_oauth, [])
    |> Keyword.get(:redirect_uris, [])
    |> List.first()
  end

  defp oauth_not_configured(conn, provider) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        code: "oauth_not_configured",
        message: "#{provider} OAuth is not configured on this environment"
      }
    })
  end

  defp invalid_state(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "invalid_state", message: "OAuth state is invalid or expired"}})
  end

  defp invalid_redirect_uri(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "invalid_redirect_uri",
        message: "Redirect URI is not allowed for this environment"
      }
    })
  end

  defp token_exchange_failed(conn, provider) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{
      error: %{
        code: "token_exchange_failed",
        message: "#{provider} rejected the authorization code"
      }
    })
  end
end
