defmodule Mokaid.Integrations.TokenRefresher do
  @moduledoc """
  Returns always-fresh OAuth credentials for an integration connection.

  Google and Microsoft access tokens expire after ~1 hour. Background mail sync
  needs valid tokens at any time, so this module transparently refreshes them
  from the stored `refresh_token` (and persists the rotated credentials).
  """

  import Ecto.Query

  alias Mokaid.Integrations
  alias Mokaid.Repo
  alias Mokaid.Integrations.{GoogleOAuth, IntegrationConnection, MicrosoftOAuth}

  require Logger

  # Refresh slightly before real expiry so in-flight requests never hit a 401.
  @expiry_margin_seconds 120

  @doc """
  Decrypts the connection credentials and refreshes them when close to expiry.

  Returns `{:ok, credentials_map}` with a valid `access_token`, or
  `{:error, reason}` when the connection has no usable credentials and cannot
  be refreshed.
  """
  def fresh_credentials(%IntegrationConnection{} = connection) do
    case Integrations.decrypted_credentials(connection) do
      nil ->
        {:error, :no_credentials}

      credentials ->
        if expiring?(credentials) do
          refresh_and_store(connection, credentials)
        else
          {:ok, credentials}
        end
    end
  end

  @doc "True when the credential access token expires within the safety margin."
  def expiring?(credentials) when is_map(credentials) do
    case DateTime.from_iso8601(credentials["expires_at"] || "") do
      {:ok, expires_at, _offset} ->
        DateTime.diff(expires_at, DateTime.utc_now(), :second) < @expiry_margin_seconds

      _ ->
        # No parseable expiry — assume long-lived token (GitHub-style).
        false
    end
  end

  defp refresh_and_store(connection, credentials) do
    refresh_token = credentials["refresh_token"]

    cond do
      is_nil(refresh_token) or refresh_token == "" ->
        {:error, :missing_refresh_token}

      true ->
        case do_refresh(connection, refresh_token) do
          {:ok, fresh} ->
            merged = Map.merge(credentials, fresh)

            persist_if_still_connected(connection, merged)

          {:error, reason} ->
            Logger.warning(
              "token refresh failed for connection #{connection.id}: #{inspect(reason)}"
            )

            {:error, :refresh_failed}
        end
    end
  end

  defp persist_if_still_connected(connection, credentials) do
    # A disconnect or reconnect may finish during the provider's refresh call.
    # Never resurrect cleared secrets or overwrite a newer account authorization.
    Repo.transaction(fn ->
      current =
        Repo.one(
          from c in IntegrationConnection,
            where: c.id == ^connection.id and c.workspace_id == ^connection.workspace_id,
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(current) or current.status != "connected" ->
          Repo.rollback(:credentials_changed)

        current.encrypted_credentials != connection.encrypted_credentials ->
          # Another refresh/reconnect already won. Use its usable credentials
          # instead of overwriting them or marking a healthy mailbox as broken.
          latest = Integrations.decrypted_credentials(current)

          if is_map(latest) and is_binary(latest["access_token"]) and
               latest["access_token"] != "" and not expiring?(latest),
             do: latest,
             else: Repo.rollback(:credentials_changed)

        true ->
          case Integrations.store_credentials(current, credentials) do
            {:ok, _} -> credentials
            {:error, _} -> Repo.rollback(:credential_persistence_failed)
          end
      end
    end)
  end

  defp do_refresh(connection, refresh_token) do
    connection = Mokaid.Repo.preload(connection, :provider)

    cond do
      GoogleOAuth.google_provider?(connection.provider.key) ->
        GoogleOAuth.refresh_tokens(refresh_token)

      MicrosoftOAuth.microsoft_provider?(connection.provider.key) ->
        MicrosoftOAuth.refresh_tokens(refresh_token)

      true ->
        {:error, :provider_not_refreshable}
    end
  end
end
