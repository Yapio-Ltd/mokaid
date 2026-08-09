defmodule Mokaid.Mail.ImapProbe do
  @moduledoc """
  Minimal IMAP LOGIN probe used to validate credentials before persisting an
  IMAP account. Speaks just enough IMAP over TLS: read the server greeting,
  attempt `LOGIN`, then `LOGOUT`.
  """

  @connect_timeout 8_000
  @response_timeout 8_000

  @doc """
  Attempts a TLS connection + LOGIN. Returns `:ok` or `{:error, reason}`
  where reason is `:connect_failed`, `:auth_failed` or `:protocol_error`.
  """
  def check(host, port, username, password, opts \\ [])

  def check(host, port, username, password, opts)
      when is_binary(host) and is_binary(username) and is_binary(password) do
    port = normalize_port(port)
    ssl? = Keyword.get(opts, :ssl, true)

    if ssl? do
      check_ssl(host, port, username, password)
    else
      {:error, :plaintext_not_supported}
    end
  end

  def check(_host, _port, _username, _password, _opts), do: {:error, :invalid_params}

  defp check_ssl(host, port, username, password) do
    ssl_opts = [
      :binary,
      active: false,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    case :ssl.connect(String.to_charlist(host), port, ssl_opts, @connect_timeout) do
      {:ok, socket} ->
        try do
          with {:ok, _greeting} <- recv_line(socket),
               :ok <-
                 send_line(socket, ~s(A1 LOGIN #{quote_imap(username)} #{quote_imap(password)})),
               {:ok, response} <- recv_until_tag(socket, "A1") do
            send_line(socket, "A2 LOGOUT")

            if String.contains?(response, "A1 OK") do
              :ok
            else
              {:error, :auth_failed}
            end
          else
            _ -> {:error, :protocol_error}
          end
        after
          :ssl.close(socket)
        end

      {:error, _reason} ->
        {:error, :connect_failed}
    end
  end

  defp send_line(socket, line), do: :ssl.send(socket, line <> "\r\n")

  defp recv_line(socket) do
    case :ssl.recv(socket, 0, @response_timeout) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :recv_failed}
    end
  end

  # Accumulates responses until the tagged completion line shows up.
  defp recv_until_tag(socket, tag, acc \\ "", rounds \\ 0)

  defp recv_until_tag(_socket, _tag, _acc, rounds) when rounds > 10,
    do: {:error, :too_many_rounds}

  defp recv_until_tag(socket, tag, acc, rounds) do
    case :ssl.recv(socket, 0, @response_timeout) do
      {:ok, data} ->
        acc = acc <> data

        if String.contains?(acc, "#{tag} OK") or String.contains?(acc, "#{tag} NO") or
             String.contains?(acc, "#{tag} BAD") do
          {:ok, acc}
        else
          recv_until_tag(socket, tag, acc, rounds + 1)
        end

      {:error, _} ->
        {:error, :recv_failed}
    end
  end

  # IMAP quoted string: escape backslash and double quote.
  defp quote_imap(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp normalize_port(port) when is_integer(port), do: port

  defp normalize_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {int, _} -> int
      :error -> 993
    end
  end

  defp normalize_port(_), do: 993
end
