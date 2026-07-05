# mokaid seeds — clean workspace for a fresh start.
# Run with: mix run priv/repo/seeds.exs

alias Mokaid.{
  Accounts,
  Billing,
  Drive,
  Knowledge,
  Members,
  Repo,
  Workspaces
}

alias Mokaid.Billing.Subscription
alias Mokaid.Integrations.IntegrationProvider

require Logger

Logger.info("Seeding mokaid base data...")

Members.seed_global_permissions()
Mokaid.MCP.seed_catalog()
Billing.seed_plans()

## ---------- Users ----------

tom =
  case Accounts.get_user_by_email("tom@mokaid.dev") do
    nil ->
      {:ok, user} =
        Accounts.register_user(%{
          email: "tom@mokaid.dev",
          full_name: "Tom Jami",
          password: "mokaid-dev-1234"
        })

      user

    user ->
      user
  end

## ---------- Workspace ----------

workspace =
  case Repo.get_by(Mokaid.Workspaces.Workspace, slug: "mokaid-demo") do
    nil ->
      {:ok, ws} =
        Workspaces.create_workspace(
          %{
            "name" => "mokaid Demo",
            "slug" => "mokaid-demo",
            "description" => "AI Workforce OS workspace",
            "industry" => "Technology",
            "timezone" => "Europe/Paris"
          },
          tom
        )

      ws

    ws ->
      ws
  end

ws_id = workspace.id
tom_member = Members.get_member_for_user(ws_id, tom.id)

## ---------- Drive base folders ----------

Drive.ensure_system_folder(ws_id, "Shared")
Drive.ensure_system_folder(ws_id, "Uploads")
Drive.ensure_system_folder(ws_id, "Agents")

## ---------- Knowledge categories ----------

category_specs = [
  {"Company", "#7c5cff"},
  {"Products", "#34d399"},
  {"Processes", "#60a5fa"},
  {"Marketing", "#f472b6"},
  {"Sales", "#fbbf24"},
  {"HR", "#22d3ee"},
  {"Legal", "#f87171"},
  {"Finance", "#a3e635"},
  {"Technical", "#8f72ff"}
]

for {name, color} <- category_specs do
  Knowledge.create_category(ws_id, %{"name" => name, "color" => color})
end

## ---------- Integrations ----------

provider_specs = [
  {"slack", "Slack", "Communication", "Send messages, alerts and notifications."},
  {"google_drive", "Google Drive", "Storage", "Store, access and share files."},
  {"gmail", "Gmail", "Communication", "Send and receive email."},
  {"notion", "Notion", "Productivity", "Sync pages and databases."},
  {"trello", "Trello", "Project Management", "Manage tasks and boards."},
  {"github", "GitHub", "Developer", "Sync repositories, issues and PRs."},
  {"zapier", "Zapier", "Automation", "Automate workflows between apps."},
  {"hubspot", "HubSpot", "CRM", "CRM, contacts and marketing."},
  {"microsoft_teams", "Microsoft Teams", "Communication",
   "Notifications and team collaboration."},
  {"dropbox", "Dropbox", "Storage", "Cloud storage and file sharing."},
  {"stripe", "Stripe", "Finance", "Payments and billing."},
  {"jira", "Jira", "Project Management", "Issue tracking and agile boards."},
  {"linear", "Linear", "Project Management", "Modern issue tracking."},
  {"google_calendar", "Google Calendar", "Productivity", "Sync events and schedules."},
  {"google_docs", "Google Docs", "Productivity", "Create and edit documents."},
  {"google_sheets", "Google Sheets", "Productivity", "Read and write spreadsheets."},
  {"google_meet", "Google Meet", "Communication", "Schedule and manage video meetings."}
]

for {key, name, category, description} <- provider_specs do
  Repo.insert!(
    %IntegrationProvider{key: key, name: name, category: category, description: description},
    on_conflict: :nothing
  )
end

## ---------- Billing ----------

business_plan = Billing.get_plan_by_key("business")

if business_plan do
  today = DateTime.utc_now()

  Repo.insert!(
    %Subscription{
      workspace_id: ws_id,
      plan_id: business_plan.id,
      status: "active",
      billing_cycle: "yearly",
      current_period_start: DateTime.add(today, -20, :day),
      current_period_end: DateTime.add(today, 345, :day),
      payment_method: %{"brand" => "visa", "last4" => "4242", "exp" => "04/28"}
    },
    on_conflict: :nothing
  )
end

Logger.info("Seed complete: workspace=#{ws_id}")
Logger.info("Login: tom@mokaid.dev / mokaid-dev-1234")
Logger.info("Workspace is empty — create agents, projects and tasks from the UI.")
