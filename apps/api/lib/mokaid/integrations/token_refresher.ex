defmodule Mokaid.Integrations.TokenRefresher do
  @moduledoc """
  Returns always-fresh OAuth credentials for an integration connection.

  Google and Microsoft access tokens expire after ~1 hour. Background mail sync
  needs valid tokens at any time, so this module transparently refreshes them
  from the stored `refresh_token` (and persists the rotated credentials).
  """

  alias Mokaid.Integrations
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
        # Cannot refresh — return what we have and let the caller surface a 401.
        {:ok, credentials}

      true ->
        case do_refresh(connection, refresh_token) do
          {:ok, fresh} ->
            merged = Map.merge(credentials, fresh)

            case Integrations.store_credentials(connection, merged) do
              {:ok, _updated} -> {:ok, merged}
              {:error, _} -> {:ok, merged}
            end

          {:error, reason} ->
            Logger.warning(
              "token refresh failed for connection #{connection.id}: #{inspect(reason)}"
            )

            {:error, :refresh_failed}
        end
    end
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
