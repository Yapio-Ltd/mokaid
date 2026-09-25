defmodule Mokaid.Avatars.Storage do
  @moduledoc "Copies generated assets into our permanent 3D bucket; private source photos stay in uploads."
  def put_asset(key, body, type) do
    bucket = Application.get_env(:mokaid, :storage, [])[:bucket_assets_3d]

    if is_binary(bucket) and bucket != "" do
      case ExAws.S3.put_object(bucket, key, body,
             content_type: type,
             cache_control: "public, max-age=31536000, immutable"
           )
           |> ExAws.request() do
        {:ok, _} -> :ok
        {:error, _} -> {:error, :storage_unavailable}
      end
    else
      {:error, :storage_unavailable}
    end
  end

  def get_asset(key) do
    bucket = Application.get_env(:mokaid, :storage, [])[:bucket_assets_3d]

    case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      _ -> {:error, :not_found}
    end
  end

  def put_source(workspace_id, body, type),
    do: Mokaid.Storage.upload_content(workspace_id, "avatar-reference", body, type)

  def get_source(key), do: Mokaid.Storage.get_object(key)

  def delete_source(nil), do: :ok

  def delete_source(key) do
    bucket =
      Application.get_env(:mokaid, :storage, [])[:bucket_uploads] || "mokaid-user-uploads-dev"

    ExAws.S3.delete_object(bucket, key) |> ExAws.request()
    :ok
  end
end
