defmodule Mokaid.Repo.Migrations.SeedGoogleIntegrationProviders do
  use Ecto.Migration

  # Frozen catalog data makes this migration reproducible without invoking
  # changing application code. Future releases also ensure the same catalog.
  def up do
    execute """
    INSERT INTO integration_providers
      (id, key, name, category, description, icon_slug, auth_kind, capabilities, enabled, inserted_at, updated_at)
    VALUES
      (gen_random_uuid(), 'gmail', 'Gmail', 'Communication', 'Connect and synchronize Gmail mailboxes.', 'gmail', 'oauth2', '{}', true, NOW(), NOW()),
      (gen_random_uuid(), 'google_drive', 'Google Drive', 'Storage', 'Read files and documents in Google Drive.', 'googledrive', 'oauth2', '{}', true, NOW(), NOW()),
      (gen_random_uuid(), 'google_calendar', 'Google Calendar', 'Productivity', 'Read calendar events and availability.', 'googlecalendar', 'oauth2', '{}', true, NOW(), NOW()),
      (gen_random_uuid(), 'google_docs', 'Google Docs', 'Productivity', 'Read Google documents.', 'googledocs', 'oauth2', '{}', true, NOW(), NOW()),
      (gen_random_uuid(), 'google_sheets', 'Google Sheets', 'Productivity', 'Read spreadsheets and cell values.', 'googlesheets', 'oauth2', '{}', true, NOW(), NOW()),
      (gen_random_uuid(), 'google_meet', 'Google Meet', 'Communication', 'Read Google Meet meeting details.', 'googlemeet', 'oauth2', '{}', true, NOW(), NOW())
    ON CONFLICT (key) DO NOTHING
    """
  end

  # Provider rows can own live credentials; a rollback must not delete them.
  def down, do: :ok
end
