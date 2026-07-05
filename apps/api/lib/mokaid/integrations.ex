defmodule Mokaid.Integrations do
  @moduledoc "Integration providers, connections and webhook events."

  import Ecto.Query

  alias Mokaid.Audit
  alias Mokaid.Integrations.{GoogleOAuth, IntegrationConnection, IntegrationProvider}
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
    if GoogleOAuth.google_provider?(provider_key) do
      {:error, :oauth_required}
    else
      connect_mock(workspace_id, provider_key, member)
    end
  end

  @doc "Stores Google OAuth credentials on every Google integration provider for the workspace."
  def connect_google_providers(workspace_id, member, credentials, account) do
    member = Repo.preload(member, :user)

    connections =
      GoogleOAuth.google_provider_keys()
      |> Enum.filter(&(get_provider_by_key(&1) != nil))
      |> Enum.map(fn key ->
        connect_with_credentials(workspace_id, key, member, credentials, account)
      end)
      |> Enum.reduce([], fn
        {:ok, conn}, acc -> [conn | acc]
        _, acc -> acc
      end)

    if connections == [] do
      {:error, :provider_not_found}
    else
      {:ok, Enum.reverse(connections)}
    end
  end

  @doc "Mirrors Google OAuth credentials into MCP Hub installations for Google servers."
  def sync_google_mcp_installations(workspace_id, member, credentials, account) do
    for key <- GoogleOAuth.google_provider_keys() do
      with {:ok, installation} <- MCP.install(workspace_id, key, member, %{}),
           {:ok, _} <- MCP.store_credentials(installation, credentials, account) do
        :ok
      else
        {:error, :server_not_found} -> :ok
        _ -> :ok
      end
    end

    {:ok, :synced}
  end

  defp connect_with_credentials(workspace_id, provider_key, member, credentials, account) do
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
          conflict_target: [:workspace_id, :provider_id]
        )

      with {:ok, connection} <- result,
           {:ok, updated} <- store_credentials(connection, credentials, account) do
        Audit.log(workspace_id, member, "integration.connect", "integration", updated.id, %{
          provider: provider_key,
          via: "google_oauth"
        })

        {:ok, Repo.preload(updated, :provider)}
      end
    else
      nil -> {:error, :provider_not_found}
    end
  end

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
          conflict_target: [:workspace_id, :provider_id]
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

  def store_credentials(%IntegrationConnection{} = connection, credentials, connected_account \\ nil) do
    connection
    |> Ecto.Changeset.change(
      encrypted_credentials: Vault.encrypt(credentials),
      status: "connected",
      connected_account: connected_account || connection.connected_account
    )
    |> Repo.update()
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
