defmodule Mokaid.Auth.Desktop do
  @moduledoc """
  Native public-client authorization: external-browser consent, S256 PKCE,
  single-use codes and rotating refresh token families. Only hashes of opaque
  codes/refresh tokens are persisted. Every access checks the live session/user.
  """
  import Ecto.Query
  require Logger
  alias Mokaid.Accounts.User
  alias Mokaid.Auth.{DesktopRefreshToken, DesktopRequest, DesktopSession}
  alias Mokaid.Repo

  @request_seconds 300
  @access_seconds 600
  @session_seconds 30 * 24 * 60 * 60
  @refresh_history_seconds @session_seconds + 86_400
  @access_salt "mokaid desktop access v1"
  @access_prefix "md_at_"
  @refresh_prefix "md_rt_"
  @url_token ~r/\A[A-Za-z0-9_-]+\z/
  @verifier ~r/\A[A-Za-z0-9._~-]{43,128}\z/

  def access_token?(token), do: is_binary(token) and String.starts_with?(token, @access_prefix)

  def create_request(
        %{"code_challenge" => challenge, "redirect_uri" => uri, "state" => state} = params
      ) do
    with "S256" <- Map.get(params, "code_challenge_method", "S256"),
         true <- url_token?(challenge, 43, 43),
         {:ok, decoded} <- Base.url_decode64(challenge, padding: false),
         true <- byte_size(decoded) == 32,
         true <- url_token?(state, 32, 128),
         :ok <- validate_redirect(uri) do
      Repo.insert(%DesktopRequest{
        code_challenge: challenge,
        redirect_uri: uri,
        state: state,
        expires_at: DateTime.add(DateTime.utc_now(), @request_seconds)
      })
    else
      _ -> {:error, :invalid_request}
    end
  end

  def create_request(_), do: {:error, :invalid_request}

  # Numeric IPv4 loopback only; no DNS, arbitrary schemes, userinfo, query or
  # fragments. The exact URI is bound to both the request and the code exchange.
  def validate_redirect(uri) when is_binary(uri) and byte_size(uri) <= 200 do
    case URI.parse(uri) do
      %URI{
        scheme: "http",
        host: "127.0.0.1",
        port: port,
        path: "/callback",
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when port in 1024..65535 ->
        :ok

      _ ->
        {:error, :invalid_redirect_uri}
    end
  rescue
    _ -> {:error, :invalid_redirect_uri}
  end

  def validate_redirect(_), do: {:error, :invalid_redirect_uri}

  def authorization_url(%DesktopRequest{id: id}) do
    base = Application.get_env(:mokaid, :desktop_auth, [])[:web_base_url] || "https://mokaid.com"
    String.trim_trailing(base, "/") <> "/desktop/authorize?request_id=" <> id
  end

  def get_request(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %DesktopRequest{} = request <- Repo.get(DesktopRequest, id),
         true <- pending?(request) do
      {:ok, request}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def approve(id, %User{id: user_id}) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        request = Repo.one(from r in DesktopRequest, where: r.id == ^id, lock: "FOR UPDATE")
        user = Repo.get(User, user_id)

        if not pending?(request) or not User.active?(user), do: Repo.rollback(:invalid_request)

        code = random_token()
        now = DateTime.utc_now()

        request
        |> Ecto.Changeset.change(code_hash: digest(code), user_id: user.id, approved_at: now)
        |> Repo.update!()

        request.redirect_uri <> "?" <> URI.encode_query(%{code: code, state: request.state})
      end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def exchange(%{"code" => code, "code_verifier" => verifier, "redirect_uri" => uri}) do
    with true <- url_token?(code, 43, 43),
         true <- is_binary(verifier) and Regex.match?(@verifier, verifier),
         :ok <- validate_redirect(uri) do
      hash = digest(code)
      challenge = verifier |> digest() |> Base.url_encode64(padding: false)

      Repo.transaction(fn ->
        request =
          Repo.one(from r in DesktopRequest, where: r.code_hash == ^hash, lock: "FOR UPDATE")

        now = DateTime.utc_now()

        if not exchangeable?(request, challenge, uri, now), do: Repo.rollback(:invalid_grant)
        user = Repo.get(User, request.user_id)
        if not User.active?(user), do: Repo.rollback(:invalid_grant)

        request |> Ecto.Changeset.change(consumed_at: now) |> Repo.update!()

        session =
          Repo.insert!(%DesktopSession{
            user_id: user.id,
            expires_at: DateTime.add(now, @session_seconds)
          })

        issue_tokens(session, user, now)
      end)
    else
      _ -> {:error, :invalid_grant}
    end
  end

  def exchange(_), do: {:error, :invalid_grant}

  # Legacy clients retain strict single-use refresh semantics.
  def refresh(token), do: rotate_refresh(token, nil)

  @doc "Retry a rotation using a request ID persisted with the current credential."
  def refresh(token, request_id) do
    if url_token?(request_id, 43, 43),
      do: rotate_refresh(token, request_id),
      else: {:error, :invalid_grant}
  end

  defp rotate_refresh(token, request_id) do
    with {:ok, token_row} <- find_refresh(token) do
      # The family lock serializes refresh/revoke and all token generations.
      Repo.transaction(fn ->
        session = lock_session(token_row.session_id)
        current = Repo.get(DesktopRefreshToken, token_row.id)
        now = DateTime.utc_now()
        user = if session, do: Repo.get(User, session.user_id)

        cond do
          not active_session?(session, now) or is_nil(current) ->
            {:error, :invalid_grant}

          not User.active?(user) ->
            revoke_session(session, now)
            {:replayed, session.id}

          not is_nil(current.used_at) ->
            case retry_refresh(current, token, request_id) do
              nil ->
                revoke_session(session, now)
                {:replayed, session.id}

              refresh ->
                {:ok, token_response(session, user, now, refresh)}
            end

          true ->
            current
            |> Ecto.Changeset.change(
              used_at: now,
              refresh_request_id_hash: if(request_id, do: digest(request_id))
            )
            |> Repo.update!()

            session =
              session
              |> Ecto.Changeset.change(expires_at: DateTime.add(now, @session_seconds))
              |> Repo.update!()

            refresh =
              if request_id,
                do: derived_refresh(token, request_id),
                else: @refresh_prefix <> random_token()

            {:ok, issue_tokens(session, user, now, refresh)}
        end
      end)
      |> case do
        {:ok, {:replayed, id}} ->
          disconnect(id)
          Logger.warning("Desktop refresh refused; session family revoked")
          {:error, :invalid_grant}

        {:ok, result} ->
          result

        {:error, _} ->
          {:error, :invalid_grant}
      end
    end
  end

  @doc "Revoke every native session when the account password changes."
  def revoke_all(user_id) do
    now = DateTime.utc_now()

    {_, ids} =
      Repo.update_all(
        from(s in DesktopSession,
          where: s.user_id == ^user_id and is_nil(s.revoked_at),
          select: s.id
        ),
        set: [revoked_at: now]
      )

    Enum.each(ids, &disconnect/1)
    :ok
  end

  # RFC 7009-style idempotent response, including unknown tokens.
  def revoke(token) do
    with {:ok, row} <- find_refresh(token),
         {:ok, id} <-
           Repo.transaction(fn ->
             session = lock_session(row.session_id)
             if session, do: revoke_session(session, DateTime.utc_now())
             row.session_id
           end) do
      disconnect(id)
    end

    :ok
  end

  @doc "Delete expired authorization material after a one-day diagnostic retention window."
  def prune_expired do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -86_400)
    Repo.delete_all(from r in DesktopRequest, where: r.expires_at < ^cutoff)

    Repo.delete_all(
      from s in DesktopSession, where: s.expires_at < ^cutoff or s.revoked_at < ^cutoff
    )

    # Rolling sessions can stay active indefinitely. Keep a spent generation
    # through the full recovery/inactivity window plus one day, then forget it.
    # It can no longer authorize or recover a live unused successor at that age.
    refresh_cutoff = DateTime.add(now, -@refresh_history_seconds)

    Repo.delete_all(
      from t in DesktopRefreshToken,
        where: not is_nil(t.used_at) and t.used_at < ^refresh_cutoff
    )

    :ok
  end

  def verify_access(@access_prefix <> signed) do
    with {:ok, %{session_id: id, user_id: user_id, expires_at: expiry}} <-
           Phoenix.Token.verify(MokaidWeb.Endpoint, @access_salt, signed,
             max_age: @access_seconds
           ),
         true <- is_integer(expiry) and expiry > System.system_time(:second),
         {:ok, user} <- validate_session(id, user_id) do
      {:ok, user, %{desktop_session_id: id, access_expires_at: expiry}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def verify_access(_), do: {:error, :unauthorized}

  def validate_session(id, user_id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %DesktopSession{user_id: ^user_id} = session <- Repo.get(DesktopSession, id),
         true <- active_session?(session, DateTime.utc_now()),
         %User{} = user <- Repo.get(User, user_id),
         true <- User.active?(user) do
      {:ok, user}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp issue_tokens(session, user, now, refresh \\ @refresh_prefix <> random_token()) do
    Repo.insert!(%DesktopRefreshToken{session_id: session.id, token_hash: digest(refresh)})
    token_response(session, user, now, refresh)
  end

  defp token_response(session, user, now, refresh) do
    expiry = min(DateTime.to_unix(now) + @access_seconds, DateTime.to_unix(session.expires_at))

    access =
      Phoenix.Token.sign(MokaidWeb.Endpoint, @access_salt, %{
        session_id: session.id,
        user_id: user.id,
        expires_at: expiry
      })

    %{
      access_token: @access_prefix <> access,
      refresh_token: refresh,
      token_type: "Bearer",
      expires_in: expiry - DateTime.to_unix(now),
      user: user
    }
  end

  # A retry may recover only the immediate, still-unused successor. Holding an
  # old credential alone cannot recover it or bypass family replay detection.
  # Both inputs stay in the client's credential vault; only their hashes persist
  # here. The domain-separated HMAC recreates the same successor after a restart.
  defp retry_refresh(%{refresh_request_id_hash: hash} = current, token, request_id)
       when is_binary(hash) and is_binary(request_id) do
    if Plug.Crypto.secure_compare(hash, digest(request_id)) do
      refresh = derived_refresh(token, request_id)

      if Repo.exists?(
           from t in DesktopRefreshToken,
             where:
               t.session_id == ^current.session_id and t.token_hash == ^digest(refresh) and
                 is_nil(t.used_at)
         ),
         do: refresh
    end
  end

  defp retry_refresh(_, _, _), do: nil

  defp derived_refresh(token, request_id) do
    secret =
      :crypto.mac(:hmac, :sha256, token, "mokaid desktop refresh retry v1:" <> request_id)
      |> Base.url_encode64(padding: false)

    @refresh_prefix <> secret
  end

  defp pending?(%DesktopRequest{approved_at: nil, consumed_at: nil, expires_at: expires}),
    do: DateTime.compare(expires, DateTime.utc_now()) == :gt

  defp pending?(_), do: false

  defp exchangeable?(
         %DesktopRequest{consumed_at: nil, approved_at: approved} = request,
         challenge,
         uri,
         now
       )
       when not is_nil(approved) do
    request.redirect_uri == uri and DateTime.compare(request.expires_at, now) == :gt and
      Plug.Crypto.secure_compare(request.code_challenge, challenge)
  end

  defp exchangeable?(_, _, _, _), do: false

  defp active_session?(%DesktopSession{revoked_at: nil, expires_at: expires}, now),
    do: DateTime.compare(expires, now) == :gt

  defp active_session?(_, _), do: false

  defp find_refresh(@refresh_prefix <> secret = token) do
    if url_token?(secret, 43, 43) do
      case Repo.get_by(DesktopRefreshToken, token_hash: digest(token)) do
        nil -> {:error, :invalid_grant}
        row -> {:ok, row}
      end
    else
      {:error, :invalid_grant}
    end
  end

  defp find_refresh(_), do: {:error, :invalid_grant}

  defp lock_session(id),
    do: Repo.one(from s in DesktopSession, where: s.id == ^id, lock: "FOR UPDATE")

  defp revoke_session(session, now),
    do: session |> Ecto.Changeset.change(revoked_at: session.revoked_at || now) |> Repo.update!()

  defp disconnect(id),
    do: MokaidWeb.Endpoint.broadcast("desktop_session:" <> id, "disconnect", %{})

  defp random_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value)

  defp url_token?(value, min, max),
    do: is_binary(value) and byte_size(value) in min..max and Regex.match?(@url_token, value)
end
