defmodule Mokaid.Integrations.LogoAssets do
  @moduledoc """
  Uploads official full-color brand logos from `priv/integration-logos/`
  into S3/MinIO under `static/integration-logos/`, and stamps
  `logo_storage_key` on every catalog row that matches a file.

  This is the single source of truth for logos across the app: the MCP Hub
  catalog (`Mokaid.MCP.Server`, 92+ entries) and the legacy workspace
  integrations list (`Mokaid.Integrations.IntegrationProvider`) both read
  from the same uploaded assets, keyed by provider/server `key`.

  Source files are committed in the repo (Wikimedia Commons / official brand
  assets). Every key is matched against `<key>.svg`, `<key>.png`, `<key>.jpg`
  or `<key>.webp` in that directory — whichever exists is uploaded. Run via
  seeds or `mix mokaid.seed_integration_logos`.
  """

  alias Mokaid.Integrations.IntegrationProvider
  alias Mokaid.MCP.Server, as: MCPServer
  alias Mokaid.Repo
  alias Mokaid.Storage

  @priv_dir Path.join(:code.priv_dir(:mokaid), "integration-logos")
  @extensions ~w(svg png jpg webp)

  @doc "Uploads bundled logos and stamps `logo_storage_key` on every matching catalog row."
  def seed_all do
    Repo.all(MCPServer) |> Enum.each(&seed_one/1)
    Repo.all(IntegrationProvider) |> Enum.each(&seed_one/1)

    :ok
  end

  defp seed_one(%{key: key} = record) do
    case find_file(key) do
      nil -> :skipped
      {path, ext} -> upload(record, key, path, ext)
    end
  end

  defp find_file(key) do
    Enum.find_value(@extensions, fn ext ->
      path = Path.join(@priv_dir, "#{key}.#{ext}")
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
