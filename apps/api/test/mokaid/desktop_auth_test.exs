defmodule Mokaid.Auth.DesktopTest do
  use Mokaid.DataCase, async: true

  alias Mokaid.Auth.{Desktop, DesktopRefreshToken, DesktopRequest, DesktopSession, Session}

  @redirect "http://127.0.0.1:49152/callback"
  @verifier String.duplicate("x", 64)
  @state String.duplicate("s", 43)

  defp request_attrs do
    %{
      "code_challenge" => :crypto.hash(:sha256, @verifier) |> Base.url_encode64(padding: false),
      "redirect_uri" => @redirect,
      "state" => @state
    }
  end

  defp approved_request(user) do
    {:ok, request} = Desktop.create_request(request_attrs())
    {:ok, redirect} = Desktop.approve(request.id, user)
    %{request: request, query: URI.decode_query(URI.parse(redirect).query)}
  end

  defp exchange_attrs(code),
    do: %{"code" => code, "code_verifier" => @verifier, "redirect_uri" => @redirect}

  defp tokens(user) do
    %{query: %{"code" => code}} = approved_request(user)
    {:ok, tokens} = Desktop.exchange(exchange_attrs(code))
    tokens
  end

  test "browser consent creates a single-use code bound to verifier, redirect and state" do
    user = user_fixture()
    %{request: request, query: query} = approved_request(user)
    assert query["state"] == @state
    assert Map.keys(query) |> Enum.sort() == ["code", "state"]
    assert {:error, :invalid_request} = Desktop.approve(request.id, user)
    assert {:error, :invalid_request} = Desktop.get_request(request.id)

    wrong_verifier =
      Map.put(exchange_attrs(query["code"]), "code_verifier", String.duplicate("y", 64))

    assert {:error, :invalid_grant} = Desktop.exchange(wrong_verifier)

    wrong_redirect =
      Map.put(exchange_attrs(query["code"]), "redirect_uri", "http://127.0.0.1:49153/callback")

    assert {:error, :invalid_grant} = Desktop.exchange(wrong_redirect)
    assert {:ok, result} = Desktop.exchange(exchange_attrs(query["code"]))
    assert result.expires_in == 600
    assert result.user.id == user.id
    assert {:ok, _, %{desktop_session_id: session_id}} = Session.authenticate(result.access_token)
    assert {:error, :invalid_grant} = Desktop.exchange(exchange_attrs(query["code"]))

    stored_request = Repo.get!(DesktopRequest, request.id)
    assert stored_request.code_hash == :crypto.hash(:sha256, query["code"])
    refute stored_request.code_hash == query["code"]

    assert Repo.one!(from t in DesktopRefreshToken, where: t.session_id == ^session_id).token_hash ==
             :crypto.hash(:sha256, result.refresh_token)
  end

  test "rejects malformed challenges, weak state and non-loopback callback targets" do
    for uri <- [
          "https://example.com/callback",
          "http://localhost:49152/callback",
          "http://127.0.0.1.evil.test:49152/callback",
          "http://127.0.0.1:80/callback",
          "http://user@127.0.0.1:49152/callback",
          "http://127.0.0.1:49152/callback?evil=1",
          "http://127.0.0.1:49152/callback#fragment",
          "file:///callback",
          "http://[::1]:49152/callback",
          "http://127.0.0.1:49152/other"
        ] do
      assert {:error, :invalid_request} =
               Desktop.create_request(Map.put(request_attrs(), "redirect_uri", uri))
    end

    for attrs <- [
          %{},
          %{"state" => "short"},
          %{"code_challenge" => "plain-secret"},
          %{"state" => %{}},
          %{"code_challenge" => nil}
        ] do
      candidate = if attrs == %{}, do: attrs, else: Map.merge(request_attrs(), attrs)
      assert {:error, :invalid_request} = Desktop.create_request(candidate)
    end

    assert {:error, :invalid_request} = Desktop.get_request("not-a-uuid")
  end

  test "expired requests cannot be approved or exchanged" do
    user = user_fixture()
    {:ok, pending} = Desktop.create_request(request_attrs())
    pending |> change(expires_at: DateTime.add(DateTime.utc_now(), -1)) |> Repo.update!()
    assert {:error, :invalid_request} = Desktop.approve(pending.id, user)
    %{request: approved, query: query} = approved_request(user)
    approved |> change(expires_at: DateTime.add(DateTime.utc_now(), -1)) |> Repo.update!()
    assert {:error, :invalid_grant} = Desktop.exchange(exchange_attrs(query["code"]))
  end

  test "refresh rotates and replay revokes the complete family after further rotations" do
    first = tokens(user_fixture())
    assert {:ok, second} = Desktop.refresh(first.refresh_token)
    assert second.refresh_token != first.refresh_token
    assert {:ok, third} = Desktop.refresh(second.refresh_token)
    assert {:ok, _, %{desktop_session_id: session_id}} = Desktop.verify_access(third.access_token)
    assert {:error, :invalid_grant} = Desktop.refresh(first.refresh_token)
    assert {:error, :invalid_grant} = Desktop.refresh(third.refresh_token)
    assert {:error, :unauthorized} = Desktop.verify_access(first.access_token)
    assert {:error, :unauthorized} = Desktop.verify_access(third.access_token)
    assert Repo.get!(DesktopSession, session_id).revoked_at
  end

  test "retrying a lost refresh response recovers the same successor without another rotation" do
    first = tokens(user_fixture())
    request_id = String.duplicate("r", 43)
    assert {:ok, second} = Desktop.refresh(first.refresh_token, request_id)
    assert second.refresh_token != first.refresh_token

    assert {:ok, _, %{desktop_session_id: session_id}} =
             Desktop.verify_access(second.access_token)

    expiry = Repo.get!(DesktopSession, session_id).expires_at

    # No process-local cache participates: repeat from the persisted predecessor.
    for _ <- 1..3 do
      assert {:ok, recovered} = Desktop.refresh(first.refresh_token, request_id)
      assert recovered.refresh_token == second.refresh_token
      assert {:ok, _, _} = Desktop.verify_access(recovered.access_token)
    end

    assert Repo.aggregate(
             from(t in DesktopRefreshToken, where: t.session_id == ^session_id),
             :count
           ) ==
             2

    stored =
      Repo.get_by!(DesktopRefreshToken, token_hash: :crypto.hash(:sha256, first.refresh_token))

    assert stored.refresh_request_id_hash == :crypto.hash(:sha256, request_id)
    assert Repo.get!(DesktopSession, session_id).expires_at == expiry
    assert {:ok, _} = Desktop.refresh(second.refresh_token, String.duplicate("n", 43))
  end

  test "retryable refresh keeps active sessions alive for another thirty days" do
    first = tokens(user_fixture())
    {:ok, _, %{desktop_session_id: id}} = Desktop.verify_access(first.access_token)
    near_expiry = DateTime.add(DateTime.utc_now(), 60)
    Repo.get!(DesktopSession, id) |> change(expires_at: near_expiry) |> Repo.update!()
    before_refresh = DateTime.utc_now()

    assert {:ok, second} = Desktop.refresh(first.refresh_token, String.duplicate("r", 43))
    assert second.expires_in == 600
    renewed = Repo.get!(DesktopSession, id)
    assert DateTime.diff(renewed.expires_at, before_refresh) >= 30 * 24 * 60 * 60
  end

  test "a different request ID or legacy replay revokes a retryable family" do
    for replay <- [:wrong_id, :legacy] do
      first = tokens(user_fixture())
      assert {:ok, second} = Desktop.refresh(first.refresh_token, String.duplicate("r", 43))

      result =
        case replay do
          :wrong_id -> Desktop.refresh(first.refresh_token, String.duplicate("w", 43))
          :legacy -> Desktop.refresh(first.refresh_token)
        end

      assert {:error, :invalid_grant} = result
      assert {:error, :unauthorized} = Desktop.verify_access(second.access_token)

      assert {:error, :invalid_grant} =
               Desktop.refresh(second.refresh_token, String.duplicate("n", 43))
    end
  end

  test "retry cannot recover a successor after that successor has been consumed" do
    first = tokens(user_fixture())
    request_id = String.duplicate("r", 43)
    {:ok, second} = Desktop.refresh(first.refresh_token, request_id)
    {:ok, third} = Desktop.refresh(second.refresh_token, String.duplicate("n", 43))
    assert {:error, :invalid_grant} = Desktop.refresh(first.refresh_token, request_id)
    assert {:error, :unauthorized} = Desktop.verify_access(third.access_token)
  end

  test "legacy rotations cannot be recovered by adding a request ID afterwards" do
    first = tokens(user_fixture())
    {:ok, second} = Desktop.refresh(first.refresh_token)

    assert {:error, :invalid_grant} =
             Desktop.refresh(first.refresh_token, String.duplicate("r", 43))

    assert {:error, :unauthorized} = Desktop.verify_access(second.access_token)
  end

  test "malformed retry IDs do not consume a valid refresh credential" do
    first = tokens(user_fixture())

    for request_id <- [
          nil,
          "",
          "short",
          String.duplicate("r", 44),
          String.duplicate("+", 43),
          %{}
        ] do
      assert {:error, :invalid_grant} = Desktop.refresh(first.refresh_token, request_id)
    end

    assert {:ok, _} = Desktop.refresh(first.refresh_token, String.duplicate("r", 43))
  end

  test "retry recovery still rejects revoked, expired and suspended sessions" do
    for invalidation <- [:revoked, :expired, :suspended] do
      user = user_fixture()
      first = tokens(user)
      request_id = String.duplicate("r", 43)
      {:ok, second} = Desktop.refresh(first.refresh_token, request_id)
      {:ok, _, %{desktop_session_id: id}} = Desktop.verify_access(second.access_token)

      case invalidation do
        :revoked ->
          Desktop.revoke(second.refresh_token)

        :expired ->
          Repo.get!(DesktopSession, id)
          |> change(expires_at: DateTime.add(DateTime.utc_now(), -1))
          |> Repo.update!()

        :suspended ->
          user |> change(status: "suspended") |> Repo.update!()
      end

      assert {:error, :invalid_grant} = Desktop.refresh(first.refresh_token, request_id)

      assert {:error, :invalid_grant} =
               Desktop.refresh(second.refresh_token, String.duplicate("n", 43))
    end
  end

  test "revocation accepts spent refresh token, disconnects socket and leaves another family active" do
    user = user_fixture()
    first = tokens(user)
    other = tokens(user)
    {:ok, second} = Desktop.refresh(first.refresh_token)
    {:ok, _, %{desktop_session_id: id}} = Desktop.verify_access(second.access_token)
    MokaidWeb.Endpoint.subscribe("desktop_session:" <> id)
    assert :ok = Desktop.revoke(first.refresh_token)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert {:error, :unauthorized} = Session.authenticate(second.access_token)
    assert {:ok, _, _} = Session.authenticate(other.access_token)
    assert :ok = Desktop.revoke(first.refresh_token)
    assert :ok = Desktop.revoke("unknown")
    assert :ok = Desktop.revoke(nil)
  end

  test "account suspension prevents approvals, code exchange, access and refresh" do
    user = user_fixture()
    live = tokens(user)
    %{query: query} = approved_request(user)
    {:ok, pending} = Desktop.create_request(request_attrs())
    user |> change(status: "suspended") |> Repo.update!()
    assert {:error, :invalid_request} = Desktop.approve(pending.id, user)
    assert {:error, :invalid_grant} = Desktop.exchange(exchange_attrs(query["code"]))
    assert {:error, :unauthorized} = Session.authenticate(live.access_token)
    assert {:error, :invalid_grant} = Desktop.refresh(live.refresh_token)
  end

  test "session expiry and access expiry are enforced independently" do
    result = tokens(user_fixture())
    {:ok, user, %{desktop_session_id: id}} = Desktop.verify_access(result.access_token)

    expired =
      Phoenix.Token.sign(MokaidWeb.Endpoint, "mokaid desktop access v1", %{
        session_id: id,
        user_id: user.id,
        expires_at: System.system_time(:second) - 1
      })

    assert {:error, :unauthorized} = Desktop.verify_access("md_at_" <> expired)

    Repo.get!(DesktopSession, id)
    |> change(expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:error, :unauthorized} = Desktop.verify_access(result.access_token)
    assert {:error, :invalid_grant} = Desktop.refresh(result.refresh_token)
  end

  test "live account roles are read on each API authentication" do
    user = user_fixture() |> change(is_platform_admin: true) |> Repo.update!()
    result = tokens(user)
    assert {:ok, %{is_platform_admin: true}, _} = Session.authenticate(result.access_token)
    user |> change(is_platform_admin: false) |> Repo.update!()
    assert {:ok, %{is_platform_admin: false}, _} = Session.authenticate(result.access_token)
  end

  test "cleanup retains active sessions and removes stale requests with expired credential families" do
    user = user_fixture()
    active = tokens(user)
    expired = tokens(user)
    {:ok, _, %{desktop_session_id: expired_id}} = Desktop.verify_access(expired.access_token)
    old = DateTime.add(DateTime.utc_now(), -172_800)
    Repo.get!(DesktopSession, expired_id) |> change(expires_at: old) |> Repo.update!()
    {:ok, request} = Desktop.create_request(request_attrs())
    request |> change(expires_at: old) |> Repo.update!()

    assert :ok = Desktop.prune_expired()
    assert is_nil(Repo.get(DesktopRequest, request.id))
    assert is_nil(Repo.get(DesktopSession, expired_id))
    refute Repo.exists?(from t in DesktopRefreshToken, where: t.session_id == ^expired_id)
    assert {:ok, _, _} = Desktop.verify_access(active.access_token)
  end

  test "cleanup bounds spent refresh history while preserving live sessions and recent retries" do
    first = tokens(user_fixture())
    {:ok, second} = Desktop.refresh(first.refresh_token, String.duplicate("a", 43))
    request_id = String.duplicate("b", 43)
    {:ok, third} = Desktop.refresh(second.refresh_token, request_id)
    now = DateTime.utc_now()

    old =
      Repo.get_by!(DesktopRefreshToken, token_hash: :crypto.hash(:sha256, first.refresh_token))

    old |> change(used_at: DateTime.add(now, -32 * 86_400)) |> Repo.update!()

    recent =
      Repo.get_by!(DesktopRefreshToken, token_hash: :crypto.hash(:sha256, second.refresh_token))

    recent |> change(used_at: DateTime.add(now, -30 * 86_400)) |> Repo.update!()

    assert :ok = Desktop.prune_expired()
    assert is_nil(Repo.get(DesktopRefreshToken, old.id))
    assert Repo.get(DesktopRefreshToken, recent.id)

    assert {:error, :invalid_grant} =
             Desktop.refresh(first.refresh_token, String.duplicate("a", 43))

    assert {:ok, _, _} = Desktop.verify_access(third.access_token)
    assert {:ok, recovered} = Desktop.refresh(second.refresh_token, request_id)
    assert recovered.refresh_token == third.refresh_token
    assert {:ok, _} = Desktop.refresh(third.refresh_token, String.duplicate("c", 43))
  end

  test "native sockets require a header and reject revoked or inactive sessions" do
    result = tokens(user_fixture())
    socket = %Phoenix.Socket{}
    assert :error = MokaidWeb.UserSocket.connect(%{"token" => result.access_token}, socket, %{})
    info = %{x_headers: [{"x-mokaid-authorization", "Bearer " <> result.access_token}]}
    assert {:ok, connected} = MokaidWeb.UserSocket.connect(%{}, socket, info)
    assert String.starts_with?(MokaidWeb.UserSocket.id(connected), "desktop_session:")
    :ok = Desktop.revoke(result.refresh_token)
    assert :error = MokaidWeb.UserSocket.connect(%{}, socket, info)
    assert {:stop, :normal, _} = MokaidWeb.UserSocket.handle_in({"ignored", []}, {%{}, connected})

    assert {:stop, :normal, _} =
             MokaidWeb.UserSocket.handle_info({:socket_push, :text, "ignored"}, {%{}, connected})
  end

  test "legacy auth and socket clients remain compatible and inactive users are rejected" do
    user = user_fixture()
    token = Mokaid.Auth.Token.sign(user.id)
    assert {:ok, _, %{}} = Session.authenticate(token)
    assert {:ok, _} = MokaidWeb.UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
    user |> change(status: "disabled") |> Repo.update!()
    assert {:error, :inactive} = Session.authenticate(token)
    assert :error = MokaidWeb.UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
  end
end
