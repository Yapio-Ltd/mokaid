defmodule Mokaid.Integrations.LogoAssets do
  @moduledoc """
  Official full-color brand logos for the MCP Hub and integrations catalog.

  Source files live in `priv/integration-logos/` (keyed by server/provider `key`).
  Optionally uploaded to S3/MinIO under `static/integration-logos/` via
  `seed_all/0` / `mix mokaid.seed_integration_logos`.

  Serving always falls back to the bundled priv files so logos work even when
  object storage was never seeded (common in production).
  """

  alias Mokaid.Integrations.IntegrationProvider
  alias Mokaid.MCP.Server, as: MCPServer
  alias Mokaid.Repo
  alias Mokaid.Storage

  @extensions ~w(svg png jpg webp)

  @doc "Uploads bundled logos and stamps `logo_storage_key` on every matching catalog row."
  def seed_all do
    Repo.all(MCPServer) |> Enum.each(&seed_one/1)
    Repo.all(IntegrationProvider) |> Enum.each(&seed_one/1)

    :ok
  end

  @doc """
  Loads a catalog logo by server/provider key.

  Prefers the object already in S3/MinIO; falls back to the file bundled in
  `priv/integration-logos/` so production still serves logos when object
  storage was never seeded.
  """
  def fetch(key) when is_binary(key) do
    storage_key_candidates = Enum.map(@extensions, &"static/integration-logos/#{key}.#{&1}")

    Enum.find_value(storage_key_candidates, fn storage_key ->
      case Storage.get_object(storage_key) do
        {:ok, body, content_type} -> {:ok, body, content_type}
        _ -> nil
      end
    end) || read_bundled(key)
  end

  def fetch(_), do: :error

  def fetch_for(%{logo_storage_key: sk, key: key}) when is_binary(sk) and sk != "" do
    case Storage.get_object(sk) do
      {:ok, body, content_type} -> {:ok, body, content_type}
      _ -> read_bundled(key)
    end
  end

  def fetch_for(%{key: key}), do: read_bundled(key)
  def fetch_for(_), do: :error

  def bundled?(key) when is_binary(key), do: match?({_, _}, find_file(key))
  def bundled?(_), do: false

  defp seed_one(%{key: key} = record) do
    case find_file(key) do
      nil -> :skipped
      {path, ext} -> upload(record, key, path, ext)
    end
  end

  defp read_bundled(key) when is_binary(key) do
    case find_file(key) do
      {path, ext} ->
        case File.read(path) do
          {:ok, body} -> {:ok, body, content_type(ext)}
          _ -> :error
        end

      nil ->
        :error
    end
  end

  defp read_bundled(_), do: :error

  # Runtime path (not compile-time): release priv lives under the app dir.
  defp priv_dir do
    Application.app_dir(:mokaid, "priv/integration-logos")
  end

  defp find_file(key) do
    Enum.find_value(@extensions, fn ext ->
      path = Path.join(priv_dir(), "#{key}.#{ext}")
      if File.exists?(path), do: {path, ext}
    end)
  end

  defp upload(record, key, path, ext) do
    with {:ok, body} <- File.read(path),
         content_type <- content_type(ext),
         storage_key <- "static/integration-logos/#{key}.#{ext}",
         {:ok, _} <- Storage.upload_platform_asset(storage_key, body, content_type) do
      record
      |> Ecto.Changeset.change(logo_storage_key: storage_key)
      |> Repo.update!()

      :ok
    else
      {:error, reason} ->
        require Logger
        Logger.warning("logo upload failed for #{key}: #{inspect(reason)}")
        :error
    end
  end

  defp content_type("png"), do: "image/png"
  defp content_type("jpg"), do: "image/jpeg"
  defp content_type("webp"), do: "image/webp"
  defp content_type(_), do: "image/svg+xml"
end
