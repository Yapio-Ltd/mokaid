defmodule Mokaid.Mail.ImapProbe do
  @moduledoc "Verifies an IMAP login and read-only INBOX access over authenticated TLS."
  alias Mokaid.Mail.ProbeSocket

  def check(host, port, username, password, opts \\ [])

  def check(host, port, username, password, opts)
      when is_binary(host) and is_integer(port) and port in 1..65_535 and
             is_binary(username) and is_binary(password) do
    security =
      Keyword.get(opts, :security, if(Keyword.get(opts, :ssl, true), do: "tls", else: "starttls"))

    transport = Keyword.get(opts, :transport, ProbeSocket)

    if security in ["tls", "starttls"] and safe_credentials?(username, password) do
      with {:ok, socket} <- transport.connect(host, port, security, opts) do
        try do
          with {:ok, greeting} <- transport.recv_line(socket),
               true <- Regex.match?(~r/^\* OK(?: |\r?\n)/i, greeting),
               {:ok, secured} <- secure(socket, host, security, transport, opts) do
            try do
              with :ok <-
                     command(
                       transport,
                       secured,
                       "A1",
                       "LOGIN #{quote_imap(username)} #{quote_imap(password)}",
                       :auth_failed
                     ),
                   :ok <- command(transport, secured, "A2", "EXAMINE INBOX", :inbox_unavailable) do
                transport.send_line(secured, "A3 LOGOUT")
                :ok
              end
            after
              transport.close(secured)
            end
          else
            {:error, reason} -> {:error, reason}
            _ -> {:error, :protocol_error}
          end
        after
          transport.close(socket)
        end
      end
    else
      {:error, :invalid_params}
    end
  end

  def check(_, _, _, _, _), do: {:error, :invalid_params}

  defp secure(socket, _host, "tls", _transport, _opts), do: {:ok, socket}

  defp secure(socket, host, "starttls", transport, opts) do
    with :ok <- command(transport, socket, "S1", "STARTTLS", :starttls_unavailable) do
      transport.starttls(socket, host, opts)
    end
  end

  defp command(transport, socket, tag, command, rejected) do
    with :ok <- transport.send_line(socket, "#{tag} #{command}") do
      completion(transport, socket, tag, rejected, 0)
    end
  end

  defp completion(_transport, _socket, _tag, _rejected, rounds) when rounds >= 40,
    do: {:error, :protocol_error}

  defp completion(transport, socket, tag, rejected, rounds) do
    case transport.recv_line(socket) do
      {:ok, line} ->
        case String.split(String.trim(line), " ", parts: 3) do
          [^tag, status | _] ->
            if String.upcase(status) == "OK", do: :ok, else: {:error, rejected}

          ["*", "BYE" | _] ->
            {:error, :protocol_error}

          _ ->
            completion(transport, socket, tag, rejected, rounds + 1)
        end

      _ ->
        {:error, :protocol_error}
    end
  end

  defp safe_credentials?(username, password) do
    username != "" and password != "" and
      not String.contains?(username <> password, ["\r", "\n", <<0>>])
  end

  defp quote_imap(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    ~s("#{escaped}")
  end
end
