defmodule Mokaid.Storage do
  @moduledoc """
  Object storage (S3 in prod, MinIO locally) for drive files.
  Only metadata lives in PostgreSQL; blobs are stored here.
  """

  @spec upload(String.t(), Plug.Upload.t()) ::
          {:ok, %{storage_key: String.t(), size_bytes: non_neg_integer(), checksum: String.t()}}
          | {:error, term()}
  def upload(workspace_id, %Plug.Upload{} = upload) do
    with {:ok, body} <- File.read(upload.path) do
      # Keep filenames short in the S3 key to stay under MinIO's 2 KB header limit.
      safe_name = upload.filename |> String.slice(0, 100)
      key = "workspaces/#{workspace_id}/drive/#{Ecto.UUID.generate()}/#{safe_name}"
      put_object(uploads_bucket(), key, body, upload.content_type)
    end
  end

  @doc "Uploads a workspace logo image (PNG/JPG/WebP/GIF)."
  @spec upload_workspace_logo(String.t(), Plug.Upload.t()) ::
          {:ok, %{storage_key: String.t(), size_bytes: non_neg_integer(), checksum: String.t()}}
          | {:error, term()}
  def upload_workspace_logo(workspace_id, %Plug.Upload{} = upload) do
    with {:ok, body} <- File.read(upload.path) do
      safe_name = upload.filename |> String.slice(0, 100)
      key = "workspaces/#{workspace_id}/logo/#{Ecto.UUID.generate()}/#{safe_name}"
      put_object(uploads_bucket(), key, body, upload.content_type)
    end
  end

  defp put_object(bucket, key, body, content_type) do
    checksum = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    ct = safe_content_type(content_type)

    request = ExAws.S3.put_object(bucket, key, body, content_type: ct)

    case ExAws.request(request) do
      {:ok, _} ->
        {:ok, %{storage_key: key, size_bytes: byte_size(body), checksum: checksum}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Uploads raw content (agent-produced artifacts) without a Plug.Upload."
  @spec upload_content(String.t(), String.t(), binary(), String.t() | nil) ::
          {:ok, %{storage_key: String.t(), size_bytes: non_neg_integer(), checksum: String.t()}}
          | {:error, term()}
  def upload_content(workspace_id, filename, content, content_type) when is_binary(content) do
    safe_name = filename |> String.slice(0, 100)
    key = "workspaces/#{workspace_id}/drive/#{Ecto.UUID.generate()}/#{safe_name}"
    checksum = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    ct = safe_content_type(content_type)

    request = ExAws.S3.put_object(uploads_bucket(), key, content, content_type: ct)

    case ExAws.request(request) do
      {:ok, _} ->
        {:ok, %{storage_key: key, size_bytes: byte_size(content), checksum: checksum}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec download_url(String.t()) :: {:ok, String.t()} | {:error, term()}
  def download_url(storage_key) do
    config = ExAws.Config.new(:s3)
    ExAws.S3.presigned_url(config, :get, uploads_bucket(), storage_key, expires_in: 900)
  end

  @spec get_object(String.t()) :: {:ok, binary(), String.t()} | {:error, term()}
  def get_object(storage_key) do
    case uploads_bucket() |> ExAws.S3.get_object(storage_key) |> ExAws.request() do
      {:ok, %{body: body, headers: headers}} ->
        {:ok, body, object_content_type(headers)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp object_content_type(headers) do
    Enum.find_value(headers, fn
      {"Content-Type", value} -> value |> String.split(";") |> hd() |> String.trim()
      _ -> nil
    end) || "application/octet-stream"
  end

  # MinIO rejects requests when combined header/metadata exceeds 2 KB.
  # Clamp content-type to a safe default when it's too long or nil.
  defp safe_content_type(nil), do: "application/octet-stream"

  defp safe_content_type(ct) when is_binary(ct) do
    trimmed = ct |> String.split(";") |> List.first() |> String.trim()
    if byte_size(trimmed) > 200, do: "application/octet-stream", else: trimmed
  end

  defp uploads_bucket do
    Application.get_env(:mokaid, :storage, [])
    |> Keyword.get(:bucket_uploads, "mokaid-user-uploads-dev")
  end
end
