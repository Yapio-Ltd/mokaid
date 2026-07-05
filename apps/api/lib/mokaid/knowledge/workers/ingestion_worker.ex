defmodule Mokaid.Knowledge.Workers.IngestionWorker do
  @moduledoc """
  Sends a knowledge item's text to the AI worker for chunking + embedding.
  The worker posts the embedded chunks back to `/api/worker/knowledge/:id/chunks`.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 3

  alias Mokaid.Knowledge

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"knowledge_item_id" => item_id, "workspace_id" => workspace_id}}) do
    config = Application.fetch_env!(:mokaid, :ai_worker)

    case Knowledge.get_item(workspace_id, item_id) do
      nil ->
        {:cancel, :item_not_found}

      %{body: body} when body in [nil, ""] ->
        {:cancel, :no_text_to_ingest}

      item ->
        payload = %{
          knowledge_item_id: item.id,
          workspace_id: item.workspace_id,
          text: item.body
        }

        dispatch(config[:dispatch], payload, config)
    end
  end

  defp dispatch(:sqs, payload, config) do
    config[:sqs_queue_url]
    |> ExAws.SQS.send_message(Jason.encode!(Map.put(payload, :type, "ingest")))
    |> ExAws.request()
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp dispatch(_http, payload, config) do
    case Req.post(
           url: "#{config[:url]}/ingest",
           json: payload,
           headers: [{"authorization", "Bearer #{config[:token]}"}],
           receive_timeout: 120_000,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, "ai worker returned #{status}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
