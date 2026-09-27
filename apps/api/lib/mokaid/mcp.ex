defmodule Mokaid.MCP do
  @moduledoc """
  MCP Hub: catalog of installable MCP servers, per-workspace installations
  (credentials encrypted at rest) and the agent permission matrix
  (`agent_mcp_grants`) deciding which agent may use which tool.
  """

  import Ecto.Query

  alias Mokaid.Audit
  alias Mokaid.Integrations.{GoogleOAuth, IntegrationConnection, TokenRefresher}
  alias Mokaid.MCP.{AgentGrant, Catalog, Installation, Server}
  alias Mokaid.Repo
  alias Mokaid.Vault

  ## ---------- Catalog ----------

  @doc "Upserts the static catalog into mcp_servers (idempotent, safe to rerun)."
  def seed_catalog do
    Enum.each(Catalog.entries(), fn attrs ->
      case Repo.get_by(Server, key: attrs["key"]) do
        nil -> %Server{} |> Server.changeset(attrs) |> Repo.insert!()
        server -> server |> Server.changeset(attrs) |> Repo.update!()
      end
    end)

    :ok
  end

  def list_servers do
    case load_enabled_servers() do
      [] ->
        if Application.get_env(:mokaid, :auto_seed_mcp_catalog, true) do
          # Prod/release: fill mcp_servers if migrate ran without catalog seed.
          # Disabled in test.exs — concurrent Sandbox tests deadlock on bulk seed.
          seed_catalog()
          load_enabled_servers()
        else
          []
        end

      servers ->
        servers
    end
  end

  defp load_enabled_servers do
    Repo.all(from s in Server, where: s.enabled, order_by: [desc: s.featured, asc: s.name])
  end

  def get_server_by_key(key), do: Repo.get_by(Server, key: key)

  ## ---------- Installations ----------

  def list_installations(workspace_id) do
    Repo.all(
      from i in Installation,
        where: i.workspace_id == ^workspace_id,
        preload: [:server, connected_by_member: :user]
    )
  end

  def get_installation(workspace_id, id) do
    Repo.one(
      from i in Installation,
        where: i.workspace_id == ^workspace_id and i.id == ^id,
        preload: [:server]
    )
  end

  def get_installation_by_server_key(workspace_id, server_key) do
    Repo.one(
      from i in Installation,
        join: s in assoc(i, :server),
        where: i.workspace_id == ^workspace_id and s.key == ^server_key,
        preload: [:server]
    )
  end

  @doc """
  Installs a server for a workspace.

  - `api_key` auth: pass `%{"api_key" => ...}` in credentials → connected.
  - `custom` auth: pass `%{"server_url" => ..., "token" => ...}` → connected.
  - `oauth2` auth: installed as `pending`; the OAuth callback stores the
    token via `store_credentials/3` and flips it to connected.
  """
  def install(workspace_id, server_key, member, params \\ %{}) do
    with %Server{} = server <- get_server_by_key(server_key),
         :ok <- check_integration_limit(workspace_id, server.id) do
      member = member && Repo.preload(member, :user)
      credentials = params["credentials"] || %{}
      settings = Map.take(params, ["server_url"]) |> compact()
      connected? = credentials != %{}

      attrs = %{
        "workspace_id" => workspace_id,
        "server_id" => server.id,
        "status" => if(connected?, do: "connected", else: "pending"),
        "connected_account" => params["connected_account"] || (member && member.user.email),
        "connected_by_member_id" => member && member.id,
        "settings" => settings
      }

      result =
        %Installation{}
        |> Installation.changeset(attrs)
        |> maybe_put_credentials(credentials)
        |> Repo.insert(
          on_conflict:
            {:replace,
             [:status, :connected_account, :connected_by_member_id, :settings, :updated_at]},
          conflict_target: [:workspace_id, :server_id]
        )

      with {:ok, installation} <- result do
        if connected? and installation.encrypted_credentials == nil do
          # on_conflict replace does not update credentials; do it explicitly.
          store_credentials(installation, credentials, params["connected_account"])
        end

        Audit.log(workspace_id, member, "mcp.install", "mcp_installation", installation.id, %{
          server: server_key
        })

        {:ok, Repo.preload(installation, :server, force: true)}
      end
    else
      nil -> {:error, :server_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Ensures an OAuth installation exists without overwriting an existing account or grants."
  def ensure_oauth_installation(workspace_id, server_key, member) do
    with %Server{enabled: true, auth_kind: "oauth2"} = server <- get_server_by_key(server_key),
         :ok <- check_integration_limit(workspace_id, server.id),
         {:ok, _} <-
           %Installation{}
           |> Installation.changeset(%{
             "workspace_id" => workspace_id,
             "server_id" => server.id,
             "status" => "pending",
             "connected_by_member_id" => member && member.id
           })
           |> Repo.insert(on_conflict: :nothing, conflict_target: [:workspace_id, :server_id]) do
      {:ok, get_installation_by_server_key(workspace_id, server_key)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :server_not_found}
    end
  end

  # Plan tiering: each plan caps how many distinct MCP servers a workspace may
  # install (-1 = unlimited). Reconnecting an already-installed server never
  # counts as a new integration.
  defp check_integration_limit(workspace_id, server_id) do
    limit = Mokaid.Billing.mcp_integration_limit(workspace_id)

    cond do
      limit < 0 ->
        :ok

      Repo.exists?(
        from i in Installation,
          where: i.workspace_id == ^workspace_id and i.server_id == ^server_id
      ) ->
        :ok

      installation_count(workspace_id) >= limit ->
        {:error, :mcp_integration_limit_reached}

      true ->
        :ok
    end
  end

  defp installation_count(workspace_id) do
    from(i in Installation, where: i.workspace_id == ^workspace_id)
    |> Repo.aggregate(:count)
  end

  @doc "Encrypts and stores credentials, marking the installation connected."
  def store_credentials(%Installation{} = installation, credentials, connected_account \\ nil) do
    installation
    |> Ecto.Changeset.change(
      encrypted_credentials: Vault.encrypt(credentials),
      status: "connected",
      error: nil,
      connected_account: connected_account || installation.connected_account
    )
    |> Repo.update()
  end

  @doc "Returns the decrypted credentials map, or nil."
  def decrypted_credentials(%Installation{encrypted_credentials: payload}) do
    case Vault.decrypt_map(payload) do
      {:ok, map} -> map
      :error -> nil
    end
  end

  def uninstall(%Installation{} = installation, member) do
    result = Repo.delete(installation)

    with {:ok, deleted} <- result do
      Audit.log(
        installation.workspace_id,
        member,
        "mcp.uninstall",
        "mcp_installation",
        installation.id,
        %{}
      )

      {:ok, deleted}
    end
  end

  ## ---------- Agent grants (permission matrix) ----------

  def list_grants_for_agent(workspace_id, agent_id) do
    Repo.all(
      from g in AgentGrant,
        where: g.workspace_id == ^workspace_id and g.agent_id == ^agent_id,
        preload: [installation: :server]
    )
  end

  def set_grant(workspace_id, agent_id, installation_id, granted, member) do
    result =
      %AgentGrant{}
      |> AgentGrant.changeset(%{
        "workspace_id" => workspace_id,
        "agent_id" => agent_id,
        "installation_id" => installation_id,
        "granted" => granted,
        "granted_by_member_id" => member && member.id
      })
      |> Repo.insert(
        on_conflict: {:replace, [:granted, :granted_by_member_id, :updated_at]},
        conflict_target: [:agent_id, :installation_id]
      )

    with {:ok, grant} <- result do
      Audit.log(workspace_id, member, "mcp.grant", "agent_mcp_grant", grant.id, %{
        agent_id: agent_id,
        installation_id: installation_id,
        granted: granted
      })

      {:ok, Repo.preload(grant, installation: :server)}
    end
  end

  @doc """
  Connected MCP servers this agent is allowed to use, with decrypted
  credentials — used to build the AI worker dispatch payload. An optional key
  resolves only that server for a live tool call, including rotated credentials.
  """
  def authorized_servers_for_agent(workspace_id, agent_id, key \\ nil) do
    query =
      from g in AgentGrant,
        join: i in assoc(g, :installation),
        join: s in assoc(i, :server),
        where:
          g.workspace_id == ^workspace_id and g.agent_id == ^agent_id and g.granted and
            i.workspace_id == ^workspace_id and i.status == "connected" and s.enabled,
        preload: [installation: :server]

    query = if is_binary(key), do: from([g, i, s] in query, where: s.key == ^key), else: query
    grants = Repo.all(query)

    Enum.flat_map(grants, fn grant ->
      installation = grant.installation
      server = installation.server

      if GoogleOAuth.google_provider?(server.key) do
        native_google_descriptor(grant)
      else
        url = installation.settings["server_url"] || server.server_url

        if url do
          [
            %{
              key: server.key,
              name: server.name,
              url: url,
              transport: server.transport,
              auth_kind: server.auth_kind,
              credentials: decrypted_credentials(installation) || %{}
            }
          ]
        else
          []
        end
      end
    end)
  end

  defp native_google_descriptor(grant) do
    installation = grant.installation

    with %IntegrationConnection{} = connection <- google_connection(installation),
         {:ok, _fresh} <- TokenRefresher.fresh_credentials(connection),
         # Refresh can involve network I/O. Recheck permissions and identity after
         # it finishes; a revoked grant or disconnected account must fail closed.
         %AgentGrant{} = current <- current_google_grant(grant),
         true <- same_google_binding?(installation, current.installation),
         %IntegrationConnection{id: id} = live <- google_connection(current.installation),
         true <- id == connection.id,
         {:ok, credentials} <- Vault.decrypt_map(live.encrypted_credentials),
         token when is_binary(token) and token != "" <- credentials["access_token"],
         false <- TokenRefresher.expiring?(credentials) do
      [
        %{
          key: current.installation.server.key,
          name: current.installation.server.name,
          url: "",
          transport: "google",
          auth_kind: "oauth2",
          credentials:
            Map.take(credentials, ["access_token", "scope", "expires_at", "token_type"])
        }
      ]
    else
      _ -> []
    end
  end

  defp current_google_grant(grant) do
    Repo.one(
      from g in AgentGrant,
        join: i in assoc(g, :installation),
        join: s in assoc(i, :server),
        where:
          g.id == ^grant.id and g.workspace_id == ^grant.workspace_id and
            g.agent_id == ^grant.agent_id and g.granted and
            i.workspace_id == ^grant.workspace_id and i.status == "connected" and s.enabled,
        preload: [installation: :server]
    )
  end

  defp same_google_binding?(before, after_installation) do
    before.server_id == after_installation.server_id and
      normalize_account(before.connected_account) ==
        normalize_account(after_installation.connected_account) and
      before.settings["integration_connection_id"] ==
        after_installation.settings["integration_connection_id"]
  end

  defp google_connection(installation) do
    account = normalize_account(installation.connected_account)
    key = installation.server.key

    if account == "" do
      nil
    else
      query =
        from c in IntegrationConnection,
          join: p in assoc(c, :provider),
          where:
            c.workspace_id == ^installation.workspace_id and c.status == "connected" and
              p.key == ^key and p.enabled and
              fragment("lower(trim(?))", c.connected_account) == ^account,
          preload: [:provider],
          limit: 2

      # Never fall back from an explicit pointer to another account's token.
      query =
        case installation.settings["integration_connection_id"] do
          nil ->
            query

          id ->
            case Ecto.UUID.cast(id) do
              {:ok, uuid} -> from c in query, where: c.id == ^uuid
              :error -> from c in query, where: false
            end
        end

      case Repo.all(query) do
        [connection] -> connection
        _ -> nil
      end
    end
  end

  defp normalize_account(account) when is_binary(account),
    do: account |> String.trim() |> String.downcase()

  defp normalize_account(_), do: ""

  def touch_installation(%Installation{} = installation) do
    installation
    |> Ecto.Changeset.change(last_used_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp maybe_put_credentials(changeset, credentials) when credentials == %{}, do: changeset

  defp maybe_put_credentials(changeset, credentials) do
    Ecto.Changeset.put_change(changeset, :encrypted_credentials, Vault.encrypt(credentials))
  end

  defp compact(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
