defmodule Mokaid.Repo.Migrations.ExtendNativeGoogleOauthFlows do
  use Ecto.Migration

  def change do
    alter table(:mail_oauth_flows) do
      add :provider_key, :string, null: false, default: "gmail"

      add :connection_id,
          references(:integration_connections, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
