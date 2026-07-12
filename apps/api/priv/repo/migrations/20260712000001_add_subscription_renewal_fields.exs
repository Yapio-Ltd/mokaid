defmodule Mokaid.Repo.Migrations.AddSubscriptionRenewalFields do
  use Ecto.Migration

  def change do
    alter table(:subscriptions) do
      add :renewal_failures, :integer, default: 0, null: false
      add :last_renewal_attempt_at, :utc_datetime_usec
    end
  end
end
