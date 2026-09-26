defmodule Mokaid.Mail.SmtpProbe do
  @moduledoc "Verifies SMTP authentication over TLS, without sending a message."
  alias Mokaid.Mail.ProbeSocket

  def check(host, port, username, password, opts \\ []) do
    security = Keyword.get(opts, :security, "starttls")
    transport = Keyword.get(opts, :transport, ProbeSocket)

    with {:ok, socket} <- transport.connect(host, port, security, opts) do
      try do
        with {:ok, 220, _} <- response(transport, socket),
             {:ok, secured} <- secure(socket, host, security, transport, opts) do
          try do
            with :ok <- transport.send_line(secured, "EHLO mokaid.app"),
                 {:ok, 250, capabilities} <- response(transport, secured),
                 :ok <- authenticate(transport, secured, capabilities, username, password) do
              transport.send_line(secured, "QUIT")
              :ok
            else
              {:error, reason} -> {:error, reason}
              _ -> {:error, :protocol_error}
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
  end

  defp secure(socket, _host, "tls", _transport, _opts), do: {:ok, socket}

  defp secure(socket, host, "starttls", transport, opts) do
    with :ok <- transport.send_line(socket, "EHLO mokaid.app"),
         {:ok, 250, capabilities} <- response(transport, socket),
         true <- String.contains?(String.upcase(capabilities), "STARTTLS"),
         :ok <- transport.send_line(socket, "STARTTLS"),
         {:ok, 220, _} <- response(transport, socket) do
      transport.starttls(socket, host, opts)
    else
      _ -> {:error, :starttls_unavailable}
    end
  end

  defp authenticate(transport, socket, capabilities, username, password) do
    mechanisms =
      Regex.scan(~r/^250[ -]AUTH[= ](.*)$/mi, capabilities, capture: :all_but_first)
      |> List.flatten()
      |> Enum.join(" ")
      |> String.upcase()
      |> String.split()

    cond do
      "PLAIN" in mechanisms ->
        credential = Base.encode64(<<0>> <> username <> <<0>> <> password)

        with :ok <- transport.send_line(socket, "AUTH PLAIN " <> credential) do
          case response(transport, socket) do
            {:ok, 235, _} ->
              :ok

            {:ok, 334, _} ->
              transport.send_line(socket, credential)
              authenticated(transport, socket)

            _ ->
              {:error, :auth_failed}
          end
        end

      "LOGIN" in mechanisms ->
        with :ok <- transport.send_line(socket, "AUTH LOGIN"),
             {:ok, 334, _} <- response(transport, socket),
             :ok <- transport.send_line(socket, Base.encode64(username)),
             {:ok, 334, _} <- response(transport, socket),
             :ok <- transport.send_line(socket, Base.encode64(password)) do
          authenticated(transport, socket)
        else
          _ -> {:error, :auth_failed}
        end

      true ->
        {:error, :auth_unsupported}
    end
  end

  defp authenticated(transport, socket) do
    case response(transport, socket) do
      {:ok, 235, _} -> :ok
      _ -> {:error, :auth_failed}
    end
  end

  defp response(transport, socket, lines \\ [], rounds \\ 0)
  defp response(_, _, _, rounds) when rounds >= 40, do: {:error, :protocol_error}

  defp response(transport, socket, lines, rounds) do
    case transport.recv_line(socket) do
      {:ok, <<code::binary-size(3), separator, _rest::binary>> = line} ->
        case Integer.parse(code) do
          {number, ""} when separator == ?\s ->
            {:ok, number, Enum.join(Enum.reverse([line | lines]))}

          {_number, ""} when separator == ?- ->
            response(transport, socket, [line | lines], rounds + 1)

          _ ->
            {:error, :protocol_error}
        end

      _ ->
        {:error, :protocol_error}
    end
  end
end
