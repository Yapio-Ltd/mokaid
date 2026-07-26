defmodule Mokaid.AI.WorkerClient do
  @moduledoc """
  Shared HTTP/SQS client for talking to the Python AI worker.

  Centralises dispatch-mode handling so tests (`dispatch: :none`) and
  misconfigured environments never crash on relative URLs like `/runs`.
  """

  @type result :: :ok | {:error, term()}

  @doc """
  POST `payload` to `path` on the configured AI worker.

  - `:none` — no-op (tests / offline)
  - `:sqs` — enqueue JSON on the worker SQS queue
  - `:http` — POST to `{url}{path}` when the URL has a scheme; otherwise
    return `{:error, :ai_worker_url_missing}` without raising

  Options:
  - `:config` — override Application env (tests)
  - `:receive_timeout` — Req timeout (default 30_000)
  - `:soft` — on HTTP/URL errors return `:ok` instead of `{:error, _}`
    (chat/converse niceties must never crash the caller)
  """
  @spec post(String.t(), map(), keyword()) :: result()
  def post(path, payload, opts \\ []) when is_binary(path) and is_map(payload) do
    config =
      Keyword.get_lazy(opts, :config, fn -> Application.fetch_env!(:mokaid, :ai_worker) end)

    receive_timeout = Keyword.get(opts, :receive_timeout, 30_000)
    soft? = Keyword.get(opts, :soft, false)

    case config[:dispatch] do
      :none ->
        :ok

      :sqs ->
        soften(sqs_post(config, payload), soft?)

      :http ->
        soften(http_post(config, path, payload, receive_timeout), soft?)

      _unknown ->
        # Never fall through unknown modes to HTTP with a nil URL.
        if soft?, do: :ok, else: {:error, :unsupported_dispatch}
    end
  end

  @doc "True when `url` is a non-empty absolute URL (has a scheme)."
  @spec absolute_url?(term()) :: boolean()
  def absolute_url?(url) when is_binary(url) do
    trimmed = String.trim(url)
    trimmed != "" and String.contains?(trimmed, "://")
  end

  def absolute_url?(_), do: false

  defp soften(:ok, _), do: :ok
  defp soften(_error, true), do: :ok
  defp soften(error, false), do: error

  defp sqs_post(config, payload) do
    case config[:sqs_queue_url] do
      url when is_binary(url) and url != "" ->
        url
        |> ExAws.SQS.send_message(Jason.encode!(payload))
        |> ExAws.request()
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, inspect(reason)}
        end

      _ ->
        {:error, :sqs_not_configured}
    end
  end

  defp http_post(config, path, payload, receive_timeout) do
    url = config[:url]

    if absolute_url?(url) do
      case Req.post(
             url: join_url(url, path),
             json: payload,
             headers: [{"authorization", "Bearer #{config[:token]}"}],
             receive_timeout: receive_timeout,
             retry: false
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          {:error, "worker returned #{status}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      {:error, :ai_worker_url_missing}
    end
  end

  defp join_url(base, path) do
    base = String.trim_trailing(to_string(base), "/")
    path = "/" <> String.trim_leading(path, "/")
    base <> path
  end
end
