defmodule MokaidWeb.Plugs.TrustedProxy do
  @moduledoc """
  Normalize client IP only behind the explicitly configured, single-hop ALB.
  ALB must use XFF append mode with client ports disabled. Its last XFF entry
  is the observed client; every earlier entry may be supplied by an attacker.
  Empty configuration trusts nobody. CIDRs must match only ALB subnets, with
  the API security group restricting ingress to the ALB security group.
  """
  import Plug.Conn
  import Bitwise

  def init(opts), do: opts

  def call(conn, opts) do
    cidrs =
      Keyword.get(opts, :trusted_cidrs, Application.get_env(:mokaid, :trusted_alb_cidrs, []))

    with true <- Enum.any?(cidrs, &contains?(&1, conn.remote_ip)),
         [forwarded] when byte_size(forwarded) <= 8192 <- get_req_header(conn, "x-forwarded-for"),
         true <- String.valid?(forwarded),
         last <- forwarded |> String.split(",") |> List.last() |> String.trim(),
         {:ok, client} <- parse_address(last) do
      conn |> put_private(:mokaid_proxy_peer, conn.remote_ip) |> Map.put(:remote_ip, client)
    else
      _ -> conn
    end
  end

  defp contains?(cidr, peer) when is_binary(cidr) and byte_size(cidr) <= 100 do
    with [address, prefix] <- String.split(cidr, "/", parts: 2),
         {:ok, network} <- parse_address(address),
         {prefix, ""} <- Integer.parse(prefix),
         {bits, network_value} <- address_value(network),
         {^bits, peer_value} <- address_value(peer),
         true <- prefix >= 0 and prefix <= bits do
      shift = bits - prefix
      network_value >>> shift == peer_value >>> shift
    else
      _ -> false
    end
  end

  defp contains?(_, _), do: false

  defp parse_address(address) when byte_size(address) in 1..45,
    do: :inet.parse_strict_address(String.to_charlist(address))

  defp parse_address(_), do: {:error, :invalid_address}

  defp address_value(address) when tuple_size(address) == 4,
    do: {32, Enum.reduce(Tuple.to_list(address), 0, &((&2 <<< 8) + &1))}

  defp address_value(address) when tuple_size(address) == 8,
    do: {128, Enum.reduce(Tuple.to_list(address), 0, &((&2 <<< 16) + &1))}

  defp address_value(_), do: :error
end
