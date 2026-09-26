defmodule MokaidWeb.AvatarAssetController do
  @moduledoc "Stable, unguessable media URLs for generated assets (including the native renderer)."
  use MokaidWeb, :controller
  alias Mokaid.Avatars.Generation
  alias Mokaid.Repo

  def show(conn, %{"id" => id, "token" => token, "filename" => filename}) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Generation{status: "ready", asset: %Mokaid.Assets3d.Asset{} = asset} <-
           Repo.get(Generation, id) |> Repo.preload(:asset),
         expected when is_binary(expected) <- asset.metadata["media_token"],
         true <- Plug.Crypto.secure_compare(expected, token),
         {:ok, suffix, type} <- format(filename, asset),
         key = String.replace_suffix(asset.storage_key, ".glb", suffix),
         {:ok, body} <- Mokaid.Avatars.storage().get_asset(key) do
      conn
      |> put_resp_content_type(type)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_resp(200, body)
    else
      _ -> {:error, :not_found}
    end
  end

  defp format("model.glb", _), do: {:ok, ".glb", "model/gltf-binary"}

  defp format("model.mokaidasset", %{metadata: %{"native_cdn_path" => path}})
       when is_binary(path),
       do: {:ok, ".mokaidasset", "application/octet-stream"}

  defp format("thumbnail.png", %{metadata: %{"thumbnail_url" => path} = metadata})
       when is_binary(path),
       do: {:ok, ".png", metadata["thumbnail_content_type"] || "image/png"}

  defp format(_, _), do: {:error, :not_found}
end
