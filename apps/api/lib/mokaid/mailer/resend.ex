defmodule Mokaid.Mailer.Resend do
  @moduledoc """
  Transactional email via the Resend REST API.

  All product email (mail alerts, future digests) goes out from the mokaid
  domain. The API key comes from `RESEND_API_KEY` (AWS Secrets Manager in
  deployed environments); when unset, sends become no-ops so dev and test
  environments never require credentials.
  """

  @endpoint "https://api.resend.com/emails"

  require Logger

  def configured? do
    key = config()[:api_key]
    is_binary(key) and key != ""
  end

  @doc """
  Sends one email. Returns `{:ok, :sent}`, `{:ok, :skipped}` (not configured)
  or `{:error, reason}`.
  """
  def deliver(to, subject, html) when is_binary(to) and is_binary(subject) do
    if configured?() do
      request(to, subject, html)
    else
      Logger.debug("resend not configured — skipping email to #{to}")
      {:ok, :skipped}
    end
  end

  defp request(to, subject, html) do
    response =
      Req.post(@endpoint,
        json: %{
          from: config()[:from] || "mokaid <notifications@mokaid.com>",
          to: [to],
          subject: subject,
          html: html
        },
        headers: [{"authorization", "Bearer #{config()[:api_key]}"}],
        retry: false
      )

    case response do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, :sent}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:resend_error, status, inspect(body)}}

      {:error, exception} ->
        {:error, {:resend_error, :network, Exception.message(exception)}}
    end
  end

  defp config, do: Application.get_env(:mokaid, :resend, [])
end
