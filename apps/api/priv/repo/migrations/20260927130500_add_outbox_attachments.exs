defmodule Mokaid.Repo.Migrations.AddOutboxAttachments do
  use Ecto.Migration

  def change do
    alter table(:mail_outbox) do
      add :encrypted_attachments, :binary
    end
  end
end
