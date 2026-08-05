defmodule Mokaid.Workers.UserAnonymizationWorker do
  @moduledoc """
  Soft-deletes / anonymizes users whose `deletion_scheduled_at` has passed.
  Keeps financial + audit rows with a pseudonymized identity.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query
  require Logger

  alias Mokaid.Accounts.User
  alias Mokaid.Repo

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now()

    due =
      Repo.all(
        from u in User,
          where:
            not is_nil(u.deletion_scheduled_at) and u.deletion_scheduled_at <= ^now and
              is_nil(u.anonymized_at),
          limit: 100
      )

    Enum.each(due, &anonymize/1)
    :ok
  end

  def anonymize(%User{} = user) do
    if user.is_platform_admin do
      Logger.warning("skip anonymize platform admin #{user.id}")
      :ok
    else
      uuid = String.replace(user.id, "-", "")
      email = "deleted+#{uuid}@anonymized.local"

      user
      |> User.moderation_changeset(%{
        email: email,
        full_name: "Deleted User",
        avatar_url: nil,
        hashed_password: nil,
        cognito_sub: nil,
        status: "disabled",
        ban_reason: user.ban_reason,
        anonymized_at: DateTime.utc_now(),
        operator_notes: "anonymized_at=#{DateTime.to_iso8601(DateTime.utc_now())}",
        is_platform_admin: false
      })
      |> Repo.update()
      |> case do
        {:ok, _} ->
          Logger.info("anonymized user #{user.id}")
          :ok

        {:error, cs} ->
          Logger.error("anonymize failed #{user.id}: #{inspect(cs.errors)}")
          {:error, cs}
      end
    end
  end
end
