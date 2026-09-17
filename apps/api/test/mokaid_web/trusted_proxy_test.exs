defmodule MokaidWeb.TrustedProxyTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias MokaidWeb.Plugs.TrustedProxy

  defp request(peer, forwarded) do
    conn = %{Plug.Test.conn(:post, "/api/auth/login") | remote_ip: peer}
    if is_nil(forwarded), do: conn, else: put_req_header(conn, "x-forwarded-for", forwarded)
  end

  @peer {10, 12, 1, 25}
  @trusted [trusted_cidrs: ["10.12.1.0/24"]]

  test "an ALB append chain uses the last address regardless of forged prefix" do
    for prefix <- ["198.51.100.99", "127.0.0.1, 10.0.0.1", "not-an-ip"] do
      result = request(@peer, prefix <> ", 203.0.113.24") |> TrustedProxy.call(@trusted)
      assert result.remote_ip == {203, 0, 113, 24}
      assert result.private.mokaid_proxy_peer == @peer
    end
  end

  test "direct peers and unconfigured deployments cannot spoof their address" do
    direct = {198, 51, 100, 7}

    assert request(direct, "203.0.113.24")
           |> TrustedProxy.call(@trusted)
           |> Map.fetch!(:remote_ip) == direct

    assert request(@peer, "203.0.113.24")
           |> TrustedProxy.call(trusted_cidrs: [])
           |> Map.fetch!(:remote_ip) == @peer

    assert request({10, 12, 2, 25}, "203.0.113.24")
           |> TrustedProxy.call(@trusted)
           |> Map.fetch!(:remote_ip) == {10, 12, 2, 25}
  end

  test "IPv6 clients and explicit IPv6 proxy CIDRs are supported" do
    client = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x24}

    assert request(@peer, "198.51.100.99, 2001:db8::24")
           |> TrustedProxy.call(@trusted)
           |> Map.fetch!(:remote_ip) == client

    peer = {0x2001, 0xDB8, 1, 0, 0, 0, 0, 7}

    assert request(peer, "203.0.113.24")
           |> TrustedProxy.call(trusted_cidrs: ["2001:db8:1::/64"])
           |> Map.fetch!(:remote_ip) == {203, 0, 113, 24}

    assert request(peer, "203.0.113.24") |> TrustedProxy.call(@trusted) |> Map.fetch!(:remote_ip) ==
             peer
  end

  test "missing, duplicate, malformed and port-bearing headers fail closed" do
    for value <- [
          nil,
          "",
          "203.0.113.24,",
          "invalid",
          "999.1.1.1",
          "127.1",
          "203.0.113.24:4321",
          "[2001:db8::24]:4321",
          String.duplicate("x", 8193)
        ] do
      assert request(@peer, value) |> TrustedProxy.call(@trusted) |> Map.fetch!(:remote_ip) ==
               @peer
    end

    conn = request(@peer, "203.0.113.24")
    duplicated = %{conn | req_headers: [{"x-forwarded-for", "198.51.100.8"} | conn.req_headers]}
    assert TrustedProxy.call(duplicated, @trusted).remote_ip == @peer
  end

  test "invalid CIDRs never expand the trusted network" do
    for cidr <- ["10.12.1.0", "10.12.1.0/33", "10.12.1.0/-1", "10.12.1.0/24junk", "bad/24", nil] do
      assert request(@peer, "203.0.113.24")
             |> TrustedProxy.call(trusted_cidrs: [cidr])
             |> Map.fetch!(:remote_ip) == @peer
    end
  end
end

defmodule MokaidWeb.TrustedProxyAuthTest do
  use MokaidWeb.ConnCase, async: false

  test "auth quotas follow ALB observed clients and cannot be reset with a forged prefix", %{
    conn: conn
  } do
    previous = Application.get_env(:mokaid, :trusted_alb_cidrs, [])
    Application.put_env(:mokaid, :trusted_alb_cidrs, ["10.12.1.0/24"])
    on_exit(fn -> Application.put_env(:mokaid, :trusted_alb_cidrs, previous) end)
    conn = %{conn | remote_ip: {10, 12, 1, 25}}
    client = "198.18.#{rem(System.unique_integer([:positive]), 254)}.31"

    for attempt <- 1..15 do
      response =
        conn
        |> put_req_header("x-forwarded-for", "203.0.113.#{attempt}, #{client}")
        |> post("/api/auth/login", %{email: "absent@example.com", password: "invalid-password"})

      assert json_response(response, 401)
    end

    blocked =
      conn
      |> put_req_header("x-forwarded-for", "127.0.0.1, #{client}")
      |> post("/api/auth/login", %{email: "absent@example.com", password: "invalid-password"})

    assert json_response(blocked, 429)["error"]["code"] == "rate_limited"

    independent_client =
      conn
      |> put_req_header("x-forwarded-for", "#{client}, 198.19.0.32")
      |> post("/api/auth/login", %{email: "absent@example.com", password: "invalid-password"})

    assert json_response(independent_client, 401)
  end
end
