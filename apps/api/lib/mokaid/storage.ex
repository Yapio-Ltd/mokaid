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
      key = "workspaces/#{workspace_id}/drive/#{Ecto.UUID.generate()}/#{upload.filename}"
      checksum = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      request =
        ExAws.S3.put_object(uploads_bucket(), key, body,
          content_type: upload.content_type || "application/octet-stream"
        )

      case ExAws.request(request) do
        {:ok, _} ->
          {:ok, %{storage_key: key, size_bytes: byte_size(body), checksum: checksum}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec download_url(String.t()) :: {:ok, String.t()} | {:error, term()}
  def download_url(storage_key) do
    config = ExAws.Config.new(:s3)
    ExAws.S3.presigned_url(config, :get, uploads_bucket(), storage_key, expires_in: 900)
  end

  defp uploads_bucket do
    Application.get_env(:mokaid, :storage, [])
    |> Keyword.get(:bucket_uploads, "mokaid-user-uploads-dev")
  end
end
