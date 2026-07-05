defmodule Mokaid.Integrations do
  @moduledoc "Integration providers, connections and webhook events."

  import Ecto.Query

  alias Mokaid.Audit
  alias Mokaid.Integrations.{IntegrationConnection, IntegrationProvider}
  alias Mokaid.Repo

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
