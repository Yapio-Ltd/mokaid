defmodule Mokaid.Integrations do
  @moduledoc "Integration providers, connections and webhook events."

  import Ecto.Query

  alias Mokaid.Audit

  alias Mokaid.Integrations.{
    GitHubOAuth,
    GoogleOAuth,
    LinearOAuth,
    MicrosoftOAuth,
    NotionOAuth,
    SlackOAuth,
    IntegrationConnection,
    IntegrationProvider
  }

  alias Mokaid.MCP
  alias Mokaid.Repo
  alias Mokaid.Vault

  def list_providers do
    Repo.all(from p in IntegrationProvider, where: p.enabled, order_by: p.name)
  end

  def get_provider_by_key(key), do: Repo.get_by(IntegrationProvider, key: key)

  def list_connections(workspace_id) do
    Repo.all(
      from c in IntegrationConnection,
        where: c.workspace_id == ^workspace_id,
        preload: [:provider, connected_by_member: :user]
    )
  end

  def get_connection(workspace_id, id) do
    Repo.one(
      from c in IntegrationConnection,
        where: c.workspace_id == ^workspace_id and c.id == ^id,
        preload: [:provider]
    )
  end

  @doc "Connects a provider (mock connector — OAuth flow to be wired per provider)."
  def connect(workspace_id, provider_key, member) do
    cond do
      GoogleOAuth.google_provider?(provider_key) -> {:error, :oauth_required}
      GitHubOAuth.github_provider?(provider_key) -> {:error, :oauth_required}
      LinearOAuth.linear_provider?(provider_key) -> {:error, :oauth_required}
      NotionOAuth.notion_provider?(provider_key) -> {:error, :oauth_required}
      SlackOAuth.slack_provider?(provider_key) -> {:error, :oauth_required}
      MicrosoftOAuth.microsoft_provider?(provider_key) -> {:error, :oauth_required}
      true -> connect_mock(workspace_id, provider_key, member)
    end
  end

  @doc "Stores GitHub OAuth credentials on the workspace GitHub integration."
  def connect_github_provider(workspace_id, member, credentials, account) do
    member = Repo.preload(member, :user)

    case connect_with_credentials(
           workspace_id,
           GitHubOAuth.provider_key(),
           member,
           credentials,
           account,
           "github_oauth"
         ) do
      {:ok, connection} -> {:ok, connection}
      error -> error
    end
  end

  @doc "Mirrors GitHub OAuth credentials into the MCP Hub GitHub installation."
  def sync_github_mcp_installation(workspace_id, member, credentials, account) do
    mcp_credentials =
      Map.merge(credentials, %{
        "api_key" => credentials["access_token"],
        "token" => credentials["access_token"]
      })

    with {:ok, installation} <-
           MCP.install(workspace_id, GitHubOAuth.provider_key(), member, %{}),
         {:ok, _} <- MCP.store_credentials(installation, mcp_credentials, account) do
      {:ok, :synced}
    else
      # Mirroring into the MCP Hub is best-effort: a missing catalog entry or
      # a plan without MCP slots must not break the base OAuth connection.
      {:error, :server_not_found} -> {:ok, :synced}
      {:error, :mcp_integration_limit_reached} -> {:ok, :synced}
      other -> other
    end
  end

  @doc "Stores Linear OAuth credentials on the workspace Linear integration."
  def connect_linear_provider(workspace_id, member, credentials, account) do
    member = Repo.preload(member, :user)

    case connect_with_credentials(
           workspace_id,
           LinearOAuth.provider_key(),
           member,
           credentials,
           account,
           "linear_oauth"
         ) do
      {:ok, connection} -> {:ok, connection}
      error -> error
    end
  end

  @doc "Mirrors Linear OAuth credentials into the MCP Hub Linear installation."
  def sync_linear_mcp_installation(workspace_id, member, credentials, account) do
    mcp_credentials =
      Map.merge(credentials, %{
        "api_key" => credentials["access_token"],
        "token" => credentials["access_token"]
      })

    with {:ok, installation} <-
           MCP.install(workspace_id, LinearOAuth.provider_key(), member, %{}),
         {:ok, _} <- MCP.store_credentials(installation, mcp_credentials, account) do
      {:ok, :synced}
    else
      # Mirroring into the MCP Hub is best-effort: a missing catalog entry or
      # a plan without MCP slots must not break the base OAuth connection.
      {:error, :server_not_found} -> {:ok, :synced}
      {:error, :mcp_integration_limit_reached} -> {:ok, :synced}
      other -> other
    end
  end

  @doc "Stores Notion OAuth credentials on the workspace Notion integration."
  def connect_notion_provider(workspace_id, member, credentials, account) do
    member = Repo.preload(member, :user)

    case connect_with_credentials(
           workspace_id,
           NotionOAuth.provider_key(),
           member,
           credentials,
           account,
           "notion_oauth"
         ) do
      {:ok, connection} -> {:ok, connection}
      error -> error
    end
  end

  @doc "Mirrors Notion OAuth credentials into the MCP Hub Notion installation."
  def sync_notion_mcp_installation(workspace_id, member, credentials, account) do
    mcp_credentials =
      Map.merge(credentials, %{
        "api_key" => credentials["access_token"],
        "token" => credentials["access_token"]
      })

    with {:ok, installation} <-
           MCP.install(workspace_id, NotionOAuth.provider_key(), member, %{}),
         {:ok, _} <- MCP.store_credentials(installation, mcp_credentials, account) do
      {:ok, :synced}
    else
      # Mirroring into the MCP Hub is best-effort: a missing catalog entry or
      # a plan without MCP slots must not break the base OAuth connection.
      {:error, :server_not_found} -> {:ok, :synced}
      {:error, :mcp_integration_limit_reached} -> {:ok, :synced}
      other -> other
    end
  end

  @doc "Stores Slack OAuth credentials on the workspace Slack integration."
  def connect_slack_provider(workspace_id, member, credentials, account) do
    member = Repo.preload(member, :user)

    case connect_with_credentials(
           workspace_id,
           SlackOAuth.provider_key(),
           member,
           credentials,
           account,
           "slack_oauth"
         ) do
      {:ok, connection} -> {:ok, connection}
      error -> error
    end
  end

  @doc "Mirrors Slack OAuth credentials into the MCP Hub Slack installation."
  def sync_slack_mcp_installation(workspace_id, member, credentials, account) do
    mcp_credentials =
      Map.merge(credentials, %{
        "api_key" => credentials["access_token"],
        "token" => credentials["access_token"]
      })

    with {:ok, installation} <- MCP.install(workspace_id, SlackOAuth.provider_key(), member, %{}),
         {:ok, _} <- MCP.store_credentials(installation, mcp_credentials, account) do
      {:ok, :synced}
    else
      # Mirroring into the MCP Hub is best-effort: a missing catalog entry or
      # a plan without MCP slots must not break the base OAuth connection.
      {:error, :server_not_found} -> {:ok, :synced}
      {:error, :mcp_integration_limit_reached} -> {:ok, :synced}
      other -> other
    end
  end

  @doc "Stores Microsoft OAuth credentials on the workspace Outlook integration."
  def connect_microsoft_provider(workspace_id, member, credentials, account) do
    member = Repo.preload(member, :user)

    case connect_with_credentials(
           workspace_id,
           MicrosoftOAuth.provider_key(),
           member,
           credentials,
           account,
           "microsoft_oauth"
         ) do
      {:ok, connection} -> {:ok, connection}
      error -> error
    end
  end

  @doc "Mirrors Microsoft OAuth credentials into the MCP Hub Outlook installation."
  def sync_microsoft_mcp_installation(workspace_id, member, credentials, account) do
    mcp_credentials =
      Map.merge(credentials, %{
        "api_key" => credentials["access_token"],
        "token" => credentials["access_token"]
      })

    with {:ok, installation} <-
           MCP.install(workspace_id, MicrosoftOAuth.provider_key(), member, %{}),
         {:ok, _} <- MCP.store_credentials(installation, mcp_credentials, account) do
      {:ok, :synced}
    else
      # Mirroring into the MCP Hub is best-effort: a missing catalog entry or
      # a plan without MCP slots must not break the base OAuth connection.
      {:error, :server_not_found} -> {:ok, :synced}
      {:error, :mcp_integration_limit_reached} -> {:ok, :synced}
      other -> other
    end
  end

  @doc "Stores credentials only for the Google provider the member explicitly connected."
  def connect_google_providers(
        workspace_id,
        member,
        credentials,
        account,
        provider_key \\ "gmail"
      ) do
    member = Repo.preload(member, :user)

    with true <- GoogleOAuth.google_provider?(provider_key),
         {:ok, connection} <-
           connect_with_credentials(workspace_id, provider_key, member, credentials, account) do
      {:ok, [connection]}
    else
      false -> {:error, :invalid_provider}
      other -> other
    end
  end

  @doc "Atomically persists an OAuth connection, its mailbox, and the first sync job."
  def complete_google_connection(result, member) do
    Repo.transaction(fn ->
      with {:ok, connections} <-
             connect_google_providers(
               result.workspace_id,
               member,
               result.credentials,
               result.account,
               result.provider_key
             ),
           {:ok, account} <- register_google_mailbox(result, member, connections) do
        %{connections: connections, mail_account: account}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp register_google_mailbox(%{provider_key: "gmail"} = result, member, [connection]) do
    with {:ok, account} <-
           Mokaid.Mail.ensure_oauth_account(
             result.workspace_id,
             member,
             "gmail",
             result.account,
             connection.id
           ),
         {:ok, _job} <-
           %{"mail_account_id" => account.id}
           |> Mokaid.Mail.Workers.SyncWorker.new()
           |> Oban.insert() do
      {:ok, account}
    end
  end

  defp register_google_mailbox(_, _, _), do: {:ok, nil}

  @doc "Mirrors only the requested Google integration into the MCP Hub."
  def sync_google_mcp_installations(
        workspace_id,
        member,
        credentials,
        account,
        provider_key \\ "gmail"
      ) do
    with {:ok, installation} <- MCP.install(workspace_id, provider_key, member, %{}) do
      # The MCP catalog currently has one installation per provider. A second
      # mailbox must never silently change the identity used by an existing one.
      if installation.connected_account in [nil, account] do
        MCP.store_credentials(installation, credentials, account)
      end
    end

    {:ok, :synced}
  end

  defp connect_with_credentials(
         workspace_id,
         provider_key,
         member,
         credentials,
         account,
         via \\ "google_oauth"
       ) do
    with %IntegrationProvider{} = provider <- get_provider_by_key(provider_key) do
      attrs = %{
        "workspace_id" => workspace_id,
        "provider_id" => provider.id,
        "status" => "connected",
        "connected_account" => account || member.user.email,
        "connected_by_member_id" => member.id
      }

      result =
        %IntegrationConnection{}
        |> IntegrationConnection.changeset(attrs)
        |> Repo.insert(
          on_conflict:
            {:replace, [:status, :connected_account, :connected_by_member_id, :updated_at]},
          conflict_target: [:workspace_id, :provider_id, :connected_account],
          returning: true
        )

      with {:ok, connection} <- result,
           :ok <- require_refresh_token(provider_key, connection, credentials),
           {:ok, updated} <- store_credentials(connection, credentials, account) do
        Audit.log(workspace_id, member, "integration.connect", "integration", updated.id, %{
          provider: provider_key,
          via: via
        })

        {:ok, Repo.preload(updated, :provider)}
      end
    else
      nil -> {:error, :provider_not_found}
    end
  end

  defp require_refresh_token("gmail", connection, credentials) do
    merged = merge_credentials(connection, credentials)

    if is_binary(merged["refresh_token"]) and merged["refresh_token"] != "",
      do: :ok,
      else: {:error, :missing_refresh_token}
  end

  defp require_refresh_token(_, _, _), do: :ok

  defp connect_mock(workspace_id, provider_key, member) do
    with %IntegrationProvider{} = provider <- get_provider_by_key(provider_key) do
      result =
        %IntegrationConnection{}
        |> IntegrationConnection.changeset(%{
          "workspace_id" => workspace_id,
          "provider_id" => provider.id,
          "status" => "connected",
          "connected_account" => member.user.email,
          "connected_by_member_id" => member.id
        })
        |> Repo.insert(
          on_conflict:
            {:replace, [:status, :connected_account, :connected_by_member_id, :updated_at]},
          conflict_target: [:workspace_id, :provider_id, :connected_account],
          returning: true
        )

      with {:ok, connection} <- result do
        Audit.log(workspace_id, member, "integration.connect", "integration", connection.id, %{
          provider: provider_key
        })

        {:ok, Repo.preload(connection, :provider)}
      end
    else
      nil -> {:error, :provider_not_found}
    end
  end

  def store_credentials(
        %IntegrationConnection{} = connection,
        credentials,
        connected_account \\ nil
      ) do
    connection
    |> Ecto.Changeset.change(
      encrypted_credentials: Vault.encrypt(merge_credentials(connection, credentials)),
      status: "connected",
      connected_account: connected_account || connection.connected_account
    )
    |> Repo.update()
  end

  defp merge_credentials(connection, credentials) do
    Map.merge(
      decrypted_credentials(connection) || %{},
      Map.reject(credentials, fn {_key, value} -> is_nil(value) or value == "" end)
    )
  end

  def decrypted_credentials(%IntegrationConnection{encrypted_credentials: payload}) do
    case Vault.decrypt_map(payload) do
      {:ok, map} -> map
      :error -> nil
    end
  end

  def disconnect(%IntegrationConnection{} = connection, member) do
    result =
      connection
      |> Ecto.Changeset.change(status: "disconnected", encrypted_credentials: nil)
      |> Repo.update()

    with {:ok, updated} <- result do
      Audit.log(
        connection.workspace_id,
        member,
        "integration.disconnect",
        "integration",
        connection.id,
        %{}
      )

      {:ok, updated}
    end
  end
end
