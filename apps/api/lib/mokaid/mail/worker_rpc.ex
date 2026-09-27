defmodule Mokaid.Mail.WorkerRPC do
  @moduledoc "Synchronous private mail operations; never queued or reported successful without a response."

  def post(path, payload)
      when path in [
             "/mail/send",
             "/mail/message/action",
             "/mail/attachment",
             "/mail/message/detail"
           ] and is_map(payload) do
    config = Application.get_env(:mokaid, :ai_worker, [])
    uri = URI.parse(config[:url] || "")
    token = config[:token]

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and is_binary(token) and
         token != "" do
      options = Application.get_env(:mokaid, :mail_worker_http_options, [])
      request = Req.new(options)

      case Req.post(request,
             url: String.trim_trailing(config[:url], "/") <> path,
             json: payload,
             headers: [{"authorization", "Bearer #{token}"}],
             receive_timeout: 60_000,
             retry: false,
             redirect: false
           ) do
        {:ok, %{status: status, body: body}}
        when path == "/mail/send" and status in 200..299 and is_map(body) ->
          {:ok, body}

        {:ok, _} when path == "/mail/send" ->
          {:error, :mail_send_uncertain}

        {:error, _} when path == "/mail/send" ->
          {:error, :mail_send_uncertain}

        {:ok, %{status: status, body: %{"error" => error}}} when status in 200..499 ->
          {:error, error_code(error)}

        {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
          {:ok, body}

        {:ok, %{status: 413}} ->
          {:error, :attachment_too_large}

        _ ->
          {:error, :mail_worker_unavailable}
      end
    else
      {:error, :mail_worker_unavailable}
    end
  end

  defp error_code("auth_failed"), do: :mail_reconnect_required
  defp error_code("not_found"), do: :not_found
  defp error_code("attachment_too_large"), do: :attachment_too_large
  defp error_code("unsupported_action"), do: :mail_action_unsupported
  defp error_code("invalid_request"), do: :invalid_mail_action
  defp error_code("send_uncertain"), do: :mail_send_uncertain
  defp error_code(_), do: :mail_provider_unavailable
end
