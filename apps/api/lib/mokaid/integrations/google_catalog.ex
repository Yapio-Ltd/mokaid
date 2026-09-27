defmodule Mokaid.Integrations.GoogleCatalog do
  @moduledoc "Canonical supported Google providers, seeded without altering administrator choices."
  import Ecto.Query
  alias Mokaid.Integrations.IntegrationProvider
  alias Mokaid.Repo

  @specs [
    {"gmail", "Gmail", "Communication", "Connect and synchronize Gmail mailboxes.", "gmail"},
    {"google_drive", "Google Drive", "Storage", "Read files and documents in Google Drive.",
     "googledrive"},
    {"google_calendar", "Google Calendar", "Productivity",
     "Read calendar events and availability.", "googlecalendar"},
    {"google_docs", "Google Docs", "Productivity", "Read Google documents.", "googledocs"},
    {"google_sheets", "Google Sheets", "Productivity", "Read spreadsheets and cell values.",
     "googlesheets"},
    {"google_meet", "Google Meet", "Communication", "Read Google Meet meeting details.",
     "googlemeet"}
  ]

  def specs, do: @specs

  def ensure do
    keys = Enum.map(@specs, &elem(&1, 0))
    count = Repo.aggregate(from(p in IntegrationProvider, where: p.key in ^keys), :count)
    if count < length(keys), do: seed(), else: :ok
  end

  def seed do
    now = DateTime.utc_now()

    rows =
      Enum.map(@specs, fn {key, name, category, description, icon_slug} ->
        %{
          id: Ecto.UUID.generate(),
          key: key,
          name: name,
          category: category,
          description: description,
          icon_slug: icon_slug,
          auth_kind: "oauth2",
          capabilities: %{},
          enabled: true,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(IntegrationProvider, rows, on_conflict: :nothing, conflict_target: :key)
    :ok
  end
end
