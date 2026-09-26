defmodule Mokaid.Mail.ProbeSocket do
  @moduledoc false
  @timeout 8_000

  def connect(host, port, security, opts) do
    with {:ok, addresses} <- resolve(host) do
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @timeout)

      addresses
      |> Enum.take(4)
      |> Enum.reduce_while({:error, :connect_failed}, fn address, previous ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:halt, previous}
        else
          case connect_address(address, host, port, security, opts, min(remaining, 3_000)) do
            {:ok, _} = result -> {:halt, result}
            error -> {:cont, error}
          end
        end
      end)
    end
  end

  defp connect_address(address, host, port, "tls", opts, timeout) do
    case :ssl.connect(address, port, tls_options(host, opts), timeout) do
      {:ok, socket} -> {:ok, {:ssl, socket}}
      {:error, {:tls_alert, _}} -> {:error, :tls_failed}
      {:error, _} -> {:error, :connect_failed}
    end
  end

  defp connect_address(address, _host, port, "starttls", _opts, timeout) do
    case :gen_tcp.connect(
           address,
           port,
           [:binary, active: false, packet: :line, packet_size: 16_384],
           timeout
         ) do
      {:ok, socket} -> {:ok, {:gen_tcp, socket}}
      {:error, _} -> {:error, :connect_failed}
    end
  end

  def starttls({:gen_tcp, socket}, host, opts) do
    case :ssl.connect(socket, tls_options(host, opts), Keyword.get(opts, :timeout, @timeout)) do
      {:ok, secured} -> {:ok, {:ssl, secured}}
      {:error, _} -> {:error, :tls_failed}
    end
  end

  def send_line({transport, socket}, line), do: transport.send(socket, line <> "\r\n")
  def recv_line({transport, socket}), do: transport.recv(socket, 0, @timeout)
  def close({transport, socket}), do: transport.close(socket)

  defp tls_options(host, opts) do
    [
      :binary,
      active: false,
      packet: :line,
      packet_size: 16_384,
      verify: :verify_peer,
      cacerts: Keyword.get_lazy(opts, :cacerts, &:public_key.cacerts_get/0),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]
  end

  # Resolve once and connect to that exact public address, while retaining the
  # hostname for certificate verification. User-supplied hosts cannot probe AWS
  # metadata/internal services or change address between validation and connect.
  defp resolve(host) do
    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(String.to_charlist(host), family) do
          {:ok, values} -> values
          _ -> []
        end
      end)

    cond do
      addresses == [] -> {:error, :connect_failed}
      Enum.any?(addresses, &(not public_address?(&1))) -> {:error, :private_host}
      true -> {:ok, Enum.uniq(addresses)}
    end
  end

  def public_address?({a, b, c, _d}) do
    a not in [0, 10, 127] and a < 224 and
      not (a == 100 and b in 64..127) and not (a == 169 and b == 254) and
      not (a == 172 and b in 16..31) and not (a == 192 and b in [0, 168]) and
      not (a == 198 and b in [18, 19]) and not (a == 198 and b == 51 and c == 100) and
      not (a == 203 and b == 0 and c == 113)
  end

  def public_address?({a, _, _, _, _, _, _, _} = ip) do
    a in 0x2000..0x3FFF and not match?({0x2001, 0xDB8, _, _, _, _, _, _}, ip)
  end

  def public_address?(_), do: false
end
