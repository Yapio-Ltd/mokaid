defmodule Mokaid.Auth.Token do
  @moduledoc """
  Revocable local web sessions. Only SHA-256 hashes of 256-bit random bearer
  credentials are stored. The former stateless tokens are intentionally rejected:
  users sign in once again after this migration, so old credentials cannot bypass
  logout or password-change revocation.
  """
  import Ecto.Query
  alias Mokaid.Auth.WebSession
  alias Mokaid.Repo

  @prefix "mw_st_"
  @max_age 60 * 60 * 24 * 7

  def sign(user_id) do
    token = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Repo.insert!(%WebSession{
      user_id: user_id,
      token_hash: digest(token),
      expires_at: DateTime.add(DateTime.utc_now(), @max_age)
    })

    token
  end

  def verify(token) do
    with {:ok, session} <- lookup(token), do: {:ok, session.user_id}
  end

  def lookup(@prefix <> secret = token) when byte_size(secret) == 43 do
    case Repo.get_by(WebSession, token_hash: digest(token)) do
      %WebSession{revoked_at: nil} = session ->
        if DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt,
          do: {:ok, session},
          else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  def lookup(_), do: {:error, :unauthorized}

  def validate_session(id, user_id) do
    now = DateTime.utc_now()

    Repo.exists?(
      from s in WebSession,
        where:
          s.id == ^id and s.user_id == ^user_id and is_nil(s.revoked_at) and s.expires_at > ^now
    )
  end

  def revoke(token) do
    with {:ok, session} <- lookup(token) do
      session |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update!()
      disconnect(session.id)
    end

    :ok
  end

  def revoke_all(user_id) do
    now = DateTime.utc_now()

    {_, ids} =
      Repo.update_all(
        from(s in WebSession,
          where: s.user_id == ^user_id and is_nil(s.revoked_at),
          select: s.id
        ),
        set: [revoked_at: now]
      )

    Enum.each(ids, &disconnect/1)
    :ok
  end

  def prune_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -86_400)
    Repo.delete_all(from s in WebSession, where: s.expires_at < ^cutoff or s.revoked_at < ^cutoff)
    :ok
  end

  defp disconnect(id), do: MokaidWeb.Endpoint.broadcast("web_session:" <> id, "disconnect", %{})
  defp digest(value), do: :crypto.hash(:sha256, value)
end
