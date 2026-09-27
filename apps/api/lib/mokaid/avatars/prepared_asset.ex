defmodule Mokaid.Avatars.PreparedAsset do
  @moduledoc "Prepares and stores one immutable character revision without changing database rows."
  alias Mokaid.Avatars
  alias Mokaid.Avatars.{Glb, Meshy, NativeCooker}

  @pipeline_version 1
  def pipeline_version, do: @pipeline_version

  def prepare(row, source_glb) do
    with {:ok, normalized} <- Glb.prepare(source_glb),
         {:ok, %{glb: glb, native: native, portrait: portrait, manifest: manifest}} <-
           native_cooker().prepare(normalized),
         :ok <- NativeCooker.validate_manifest(manifest),
         true <- valid_outputs?(glb, native, portrait, manifest) do
      revision = Ecto.UUID.generate()
      key = "assets3d/generated-characters/#{row.workspace_id}/#{row.id}/#{revision}"
      token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      media = MokaidWeb.Endpoint.url() <> "/api/avatar-assets/#{row.id}/#{token}"

      with :ok <- Avatars.storage().put_asset(key <> ".glb", glb, "model/gltf-binary"),
           :ok <-
             Avatars.storage().put_asset(
               key <> ".mokaidasset",
               native,
               "application/octet-stream"
             ),
           :ok <- Avatars.storage().put_asset(key <> ".portrait.png", portrait, "image/png") do
        thumbnail = save_thumbnail(row, key, media)
        portrait_url = media <> "/portrait.png"

        {:ok,
         %{
           workspace_id: row.workspace_id,
           slug: "custom_#{row.id}",
           kind: "character",
           storage_key: key <> ".glb",
           cdn_path: media <> "/model.glb",
           sha256: digest(glb),
           byte_size: byte_size(glb),
           animation_clips: manifest["animation_clips"],
           metadata: %{
             "display_name" => row.name || "Custom character",
             "target_height_m" => 1.75,
             "source" => "generated",
             "custom" => true,
             "generation_id" => row.id,
             "media_token" => token,
             "revision" => revision,
             "pipeline_version" => @pipeline_version,
             "quality" => manifest["quality"],
             "portrait" => manifest["portrait"],
             "native_cdn_path" => media <> "/model.mokaidasset",
             "portrait_url" => portrait_url,
             "portrait_content_type" => "image/png",
             "thumbnail_url" => if(thumbnail, do: thumbnail.url, else: portrait_url),
             "thumbnail_content_type" => if(thumbnail, do: thumbnail.type, else: "image/png"),
             "skeleton" => "mokaid_office_humanoid"
           }
         }}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :avatar_preparation_failed}
    end
  rescue
    _ -> {:error, :avatar_preparation_failed}
  end

  defp valid_outputs?(glb, native, portrait, manifest) do
    is_binary(glb) and byte_size(glb) > 20 and byte_size(glb) <= 64 * 1024 * 1024 and
      String.starts_with?(glb, "glTF") and
      is_binary(native) and byte_size(native) > 8 and byte_size(native) <= 128 * 1024 * 1024 and
      String.starts_with?(native, "MOKASSET") and
      is_binary(portrait) and byte_size(portrait) <= 2 * 1024 * 1024 and
      match?(<<0x89, "PNG", 13, 10, 26, 10, _::binary>>, portrait) and
      manifest["pipeline_version"] == @pipeline_version and
      manifest["model_sha256"] == digest(glb)
  end

  defp save_thumbnail(row, key, media) do
    with {:ok, bytes} <- thumbnail_body(row),
         {:ok, type} <- Avatars.image_type(bytes),
         :ok <- Avatars.storage().put_asset(key <> ".png", bytes, type) do
      %{url: media <> "/thumbnail.png", type: type}
    else
      # The rendered portrait is always available when the character is ready.
      _ -> nil
    end
  end

  # Repair workers copy an existing object from our bucket and never request
  # upstream generation media. Fresh generations may still retain a body preview.
  defp thumbnail_body(%{stored_thumbnail: body}) when is_binary(body), do: {:ok, body}
  defp thumbnail_body(%{thumbnail_source_url: url}) when is_binary(url), do: Meshy.download(url)
  defp thumbnail_body(_), do: {:error, :no_thumbnail}

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp native_cooker,
    do: Application.get_env(:mokaid, :avatar_native_cooker, NativeCooker)
end
