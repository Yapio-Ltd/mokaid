# mokaid seeds — clean workspace for a fresh start.
# Run with: mix run priv/repo/seeds.exs

alias Mokaid.{
  Billing,
  Members,
  Repo
}

alias Mokaid.Integrations.IntegrationProvider

require Logger

Logger.info("Seeding mokaid base data...")

Members.seed_global_permissions()
Mokaid.MCP.seed_catalog()
Mokaid.Assets3d.seed_catalog()
Billing.seed_plans()

## ---------- Integrations ----------

provider_specs = [
  {"slack", "Slack", "Communication", "Send messages, alerts and notifications.", "slack"},
  {"google_drive", "Google Drive", "Storage", "Store, access and share files.", "googledrive"},
  {"gmail", "Gmail", "Communication", "Send and receive email.", "gmail"},
  {"notion", "Notion", "Productivity", "Sync pages and databases.", "notion"},
  {"trello", "Trello", "Project Management", "Manage tasks and boards.", "trello"},
  {"github", "GitHub", "Developer", "Sync repositories, issues and PRs.", "github"},
  {"zapier", "Zapier", "Automation", "Automate workflows between apps.", "zapier"},
  {"hubspot", "HubSpot", "CRM", "CRM, contacts and marketing.", "hubspot"},
  {"microsoft_teams", "Microsoft Teams", "Communication", "Notifications and team collaboration.",
   "microsoftteams"},
  {"dropbox", "Dropbox", "Storage", "Cloud storage and file sharing.", "dropbox"},
  {"stripe", "Stripe", "Finance", "Payments and billing.", "stripe"},
  {"jira", "Jira", "Project Management", "Issue tracking and agile boards.", "jira"},
  {"linear", "Linear", "Project Management", "Modern issue tracking.", "linear"},
  {"google_calendar", "Google Calendar", "Productivity", "Sync events and schedules.",
   "googlecalendar"},
  {"google_docs", "Google Docs", "Productivity", "Create and edit documents.", "googledocs"},
  {"google_sheets", "Google Sheets", "Productivity", "Read and write spreadsheets.",
   "googlesheets"},
  {"google_meet", "Google Meet", "Communication", "Schedule and manage video meetings.",
   "googlemeet"}
]

for {key, name, category, description, icon_slug} <- provider_specs do
  Repo.insert!(
    %IntegrationProvider{
      key: key,
      name: name,
      category: category,
      description: description,
      icon_slug: icon_slug
    },
    on_conflict: {:replace, [:name, :category, :description, :icon_slug, :updated_at]},
    conflict_target: :key
  )
end

for key <- ["github", "linear", "slack"] do
  if provider = Repo.get_by(IntegrationProvider, key: key) do
    provider
    |> Ecto.Changeset.change(auth_kind: "oauth2")
    |> Repo.update!()
  end
end

Mokaid.Integrations.LogoAssets.seed_all()

Logger.info("Seed complete: base catalog data only, no user accounts.")
Logger.info("Create your account and workspace from the signup page.")
