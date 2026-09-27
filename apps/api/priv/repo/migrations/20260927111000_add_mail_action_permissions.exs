defmodule Mokaid.Repo.Migrations.AddMailActionPermissions do
  use Ecto.Migration

  # Register the actions without granting them to any additional role. The
  # existing Owner/Admin policy permits them; read-only roles remain read-only.
  def up do
    execute """
    INSERT INTO permissions (id, key, description, inserted_at, updated_at)
    VALUES
      (gen_random_uuid(), 'mail.send', 'Send mail from a connected workspace mailbox', NOW(), NOW()),
      (gen_random_uuid(), 'mail.manage', 'Update flags and folders of workspace mail', NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """
  end

  def down, do: :ok
end
