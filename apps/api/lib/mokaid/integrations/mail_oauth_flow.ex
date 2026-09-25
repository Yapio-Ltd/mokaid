defmodule Mokaid.Integrations.MailOAuthFlow do
  @moduledoc "Short-lived, member-bound completion state for native mailbox authorization."
  use Ecto.Schema
  import Ecto.Query

  alias Mokaid.{Integrations, Members, Permissions, Repo}
  alias Mokaid.Integrations.GoogleOAuth

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "mail_oauth_flows" do
    field :workspace_id, :binary_id
    field :member_id, :binary_id
    field :status, :string, default: "pending"
    field :account_id, :binary_id
    field :error, :string
    field :expires_at, :utc_datetime_usec
    timestamps()
  end

  def start(workspace_id, member) do
    id = Ecto.UUID.generate()

    with :ok <- Permissions.authorize(member, "integrations.connect"),
         {:ok, url} <-
           GoogleOAuth.authorize_url(
             workspace_id,
             member.id,
             GoogleOAuth.desktop_redirect_uri(),
             "gmail",
             flow_id: id
           ),
         {:ok, _flow} <-
           Repo.insert(%__MODULE__{
             id: id,
             workspace_id: workspace_id,
             member_id: member.id,
             expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
           }) do
      # Retain completed flows long enough for clients to resume polling; old
      # state has no credentials and can be removed without affecting mailboxes.
      cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)
      Repo.delete_all(from f in __MODULE__, where: f.expires_at < ^cutoff)
      {:ok, %{authorize_url: url, flow_id: id}}
    end
  end

  def get(workspace_id, member_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %__MODULE__{} = flow <-
           Repo.get_by(__MODULE__, id: id, workspace_id: workspace_id, member_id: member_id) do
      if flow.status in ["pending", "completing"] and
           DateTime.compare(flow.expires_at, DateTime.utc_now()) != :gt do
        {:ok, %{status: "failed", error: "authorization_expired", account_id: nil}}
      else
        status = if flow.status == "completing", do: "pending", else: flow.status
        {:ok, %{status: status, error: flow.error, account_id: flow.account_id}}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def cancel(workspace_id, member_id, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, _} <- get(workspace_id, member_id, id) do
      Repo.update_all(
        from(f in __MODULE__,
          where:
            f.id == ^id and f.workspace_id == ^workspace_id and
              f.member_id == ^member_id and f.status in ["pending", "completing"]
        ),
        set: [status: "failed", error: "authorization_cancelled", updated_at: DateTime.utc_now()]
      )

      get(workspace_id, member_id, id)
    else
      _ -> {:error, :not_found}
    end
  end

  def complete(params) do
    redirect_uri = GoogleOAuth.desktop_redirect_uri()

    with {:ok, %{flow_id: id} = state} when is_binary(id) <-
           GoogleOAuth.verify_state(params["state"], redirect_uri),
         %__MODULE__{} = flow <-
           Repo.get_by(__MODULE__,
             id: id,
             workspace_id: state.workspace_id,
             member_id: state.member_id
           ),
         true <- DateTime.compare(flow.expires_at, DateTime.utc_now()) == :gt,
         :ok <- claim(flow) do
      result = finish(flow, params, redirect_uri)

      case result do
        {:ok, _completed} ->
          {:ok, :connected}

        {:error, reason} ->
          error = public_error(reason)

          Repo.update_all(
            from(f in __MODULE__, where: f.id == ^flow.id and f.status == "completing"),
            set: [status: "failed", error: error, updated_at: DateTime.utc_now()]
          )

          {:error, error}
      end
    else
      _ -> {:error, "authorization_expired"}
    end
  end

  defp claim(flow) do
    case Repo.update_all(from(f in __MODULE__, where: f.id == ^flow.id and f.status == "pending"),
           set: [status: "completing", updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> :ok
      _ -> {:error, :already_completed}
    end
  end

  defp finish(_flow, %{"error" => _}, _redirect_uri), do: {:error, :access_denied}

  defp finish(flow, params, redirect_uri) do
    with %{status: "active"} = member <- Members.get_member(flow.workspace_id, flow.member_id),
         :ok <- Permissions.authorize(member, "integrations.connect"),
         {:ok, result} <- GoogleOAuth.exchange_code(params["code"], params["state"], redirect_uri),
         {:ok, completed} <- persist_completion(flow, result) do
      {:ok, completed}
    else
      nil -> {:error, :forbidden}
      %{status: _} -> {:error, :forbidden}
      other -> other
    end
  end

  defp persist_completion(flow, result) do
    # Serialize cancellation against the commit, not the provider's network call.
    # Once cancelled, even a successful code exchange cannot attach a mailbox.
    Repo.transaction(fn ->
      locked = Repo.one(from f in __MODULE__, where: f.id == ^flow.id, lock: "FOR UPDATE")
      if is_nil(locked) or locked.status != "completing", do: Repo.rollback(:access_denied)

      if DateTime.compare(locked.expires_at, DateTime.utc_now()) != :gt,
        do: Repo.rollback(:authorization_expired)

      # Consent can outlive membership, role changes, or an account suspension.
      # Re-read after the provider call and hold these rows through the commit.
      member =
        Repo.one(
          from m in Mokaid.Members.Member,
            where: m.id == ^flow.member_id and m.workspace_id == ^flow.workspace_id,
            lock: "FOR SHARE"
        )

      if is_nil(member) or member.status != "active", do: Repo.rollback(:forbidden)

      user =
        Repo.one(
          from u in Mokaid.Accounts.User,
            where: u.id == ^member.user_id,
            lock: "FOR SHARE"
        )

      if not Mokaid.Accounts.User.active?(user), do: Repo.rollback(:forbidden)
      member = member |> Repo.preload(:role) |> Map.put(:user, user)

      if Permissions.authorize(member, "integrations.connect") != :ok,
        do: Repo.rollback(:forbidden)

      case Integrations.complete_google_connection(result, member) do
        {:ok, %{mail_account: account} = completed} ->
          Repo.update!(Ecto.Changeset.change(locked, status: "connected", account_id: account.id))
          completed

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def public_error(:authorization_expired), do: "authorization_expired"
  def public_error(:access_denied), do: "authorization_cancelled"
  def public_error(:missing_required_scopes), do: "mail_permission_required"
  def public_error(:missing_refresh_token), do: "reconnect_with_consent"
  def public_error(:forbidden), do: "workspace_access_revoked"
  def public_error(:account_fetch_failed), do: "google_account_unavailable"
  def public_error(:unverified_account), do: "google_account_unverified"
  def public_error(_), do: "connection_failed"
end
