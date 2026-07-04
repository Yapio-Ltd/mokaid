# mokaid demo seeds — matches the design mockups.
# Run with: mix run priv/repo/seeds.exs

alias Mokaid.{Accounts, Agents, Billing, Calendar, Drive, Knowledge, Members, Projects, Repo, Tasks, Workspaces}
alias Mokaid.Billing.{BillingPlan, Invoice, Subscription}
alias Mokaid.Integrations.IntegrationProvider

require Logger

Logger.info("Seeding mokaid demo data...")

Members.seed_global_permissions()

## ---------- Users ----------

demo_users = [
  %{email: "tom@mokaid.dev", full_name: "Tom Jami", password: "mokaid-dev-1234"},
  %{email: "ava@mokaid.dev", full_name: "Ava Rodriguez", password: "mokaid-dev-1234"},
  %{email: "ethan@mokaid.dev", full_name: "Ethan Carter", password: "mokaid-dev-1234"},
  %{email: "sophia@mokaid.dev", full_name: "Sophia Bennett", password: "mokaid-dev-1234"},
  %{email: "noah@mokaid.dev", full_name: "Noah Williams", password: "mokaid-dev-1234"},
  %{email: "mason@mokaid.dev", full_name: "Mason Lee", password: "mokaid-dev-1234"}
]

users =
  Map.new(demo_users, fn attrs ->
    user =
      case Accounts.get_user_by_email(attrs.email) do
        nil ->
          {:ok, user} = Accounts.register_user(attrs)
          user

        user ->
          user
      end

    {attrs.full_name, user}
  end)

tom = users["Tom Jami"]

## ---------- Workspace ----------

workspace =
  case Repo.get_by(Mokaid.Workspaces.Workspace, slug: "mokaid-demo") do
    nil ->
      {:ok, ws} =
        Workspaces.create_workspace(
          %{
            "name" => "mokaid Demo",
            "slug" => "mokaid-demo",
            "description" => "AI Workforce OS demo workspace",
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

if Repo.aggregate(Mokaid.Agents.Agent, :count) > 0 do
  Logger.info("Seeds already applied, skipping.")
else
  ## ---------- Teams ----------

  team_names = [
    {"Design Team", "#7c5cff"},
    {"Development Team", "#60a5fa"},
    {"Marketing Team", "#f472b6"},
    {"Product Team", "#34d399"},
    {"Data Team", "#fbbf24"},
    {"Support Team", "#22d3ee"}
  ]

  teams =
    Map.new(team_names, fn {name, color} ->
      {:ok, team} = Members.create_team(ws_id, %{"name" => name, "color" => color})
      {name, team}
    end)

  ## ---------- Members ----------

  member_role = Members.get_role_by_name(ws_id, "Agent User")
  tom_member = Members.get_member_for_user(ws_id, tom.id)

  member_specs = [
    {"Ava Rodriguez", "UI/UX Designer", "Design Team"},
    {"Ethan Carter", "Software Engineer", "Development Team"},
    {"Sophia Bennett", "Content Writer", "Marketing Team"},
    {"Noah Williams", "Product Manager", "Product Team"},
    {"Mason Lee", "DevOps Engineer", "Development Team"}
  ]

  members =
    Map.new(member_specs, fn {name, title, team_name} ->
      user = users[name]

      {:ok, member} =
        %Mokaid.Members.Member{}
        |> Mokaid.Members.Member.changeset(%{
          "workspace_id" => ws_id,
          "user_id" => user.id,
          "role_id" => member_role.id,
          "team_id" => teams[team_name].id,
          "title" => title,
          "status" => "active",
          "joined_at" => DateTime.utc_now(),
          "leave_balances" => %{"vacation_days" => 12, "sick_days" => 5}
        })
        |> Repo.insert()

      {name, member}
    end)

  ## ---------- Agents ----------

  human_agent_specs = [
    {"Ava Rodriguez", "UI/UX Designer", "Design", "ava", "#a78bfa",
     [%{"name" => "UI Design", "level" => 90}, %{"name" => "UX Research", "level" => 75}, %{"name" => "Figma", "level" => 85}, %{"name" => "Prototyping", "level" => 70}]},
    {"Ethan Carter", "Software Engineer", "Development", "ethan", "#60a5fa",
     [%{"name" => "React", "level" => 92}, %{"name" => "Node.js", "level" => 84}, %{"name" => "TypeScript", "level" => 88}]},
    {"Sophia Bennett", "Content Writer", "Marketing", "sophia", "#f472b6",
     [%{"name" => "Copywriting", "level" => 89}, %{"name" => "SEO", "level" => 72}, %{"name" => "Content Strategy", "level" => 80}]},
    {"Noah Williams", "Product Manager", "Product", "noah", "#34d399",
     [%{"name" => "Roadmapping", "level" => 86}, %{"name" => "User Stories", "level" => 82}, %{"name" => "Analytics", "level" => 74}]},
    {"Mason Lee", "DevOps Engineer", "IT", "mason", "#fbbf24",
     [%{"name" => "AWS", "level" => 91}, %{"name" => "Terraform", "level" => 85}, %{"name" => "CI/CD", "level" => 88}]}
  ]

  human_agents =
    human_agent_specs
    |> Enum.with_index()
    |> Map.new(fn {{name, role, dept, preset, color, skills}, index} ->
      member = members[name]

      {:ok, agent} =
        Agents.create_agent(
          ws_id,
          %{
            "kind" => "human_linked",
            "display_name" => name,
            "role_title" => role,
            "department" => dept,
            "linked_user_id" => member.user_id,
            "linked_member_id" => member.id,
            "status" => Enum.at(["active", "active", "busy", "active", "offline"], index),
            "presence_status" => Enum.at(["online", "online", "online", "away", "offline"], index),
            "ai_enabled" => false,
            "human_takeover_enabled" => false,
            "skills" => skills,
            "performance_score" => Enum.at([94, 91, 87, 89, 78], index),
            "avatar_config" => %{
              "preset" => preset,
              "primary_color" => color,
              "accent_color" => "#7c5cff",
              "seat_index" => index
            }
          },
          tom_member
        )

      {name, agent}
    end)

  ai_agent_specs = [
    {"Marketing Assistant", "Campaign Management", "Marketing", "#f472b6",
     [%{"name" => "Campaign Planning", "level" => 82}, %{"name" => "Email Drafting", "level" => 88}]},
    {"Data Analyst", "Data & Analytics", "Analytics", "#fbbf24",
     [%{"name" => "SQL", "level" => 90}, %{"name" => "Reporting", "level" => 85}, %{"name" => "Python", "level" => 80}]},
    {"Customer Support Bot", "Customer Support", "Support", "#22d3ee",
     [%{"name" => "Ticket Triage", "level" => 93}, %{"name" => "FAQ Answers", "level" => 89}]},
    {"Code Review Agent", "Development", "Engineering", "#60a5fa",
     [%{"name" => "Code Review", "level" => 87}, %{"name" => "Best Practices", "level" => 84}]},
    {"Reporting Agent", "Data & Analytics", "Reporting", "#34d399",
     [%{"name" => "Report Generation", "level" => 91}, %{"name" => "Data Viz", "level" => 78}]}
  ]

  ai_agents =
    ai_agent_specs
    |> Enum.with_index()
    |> Map.new(fn {{name, role, dept, color, skills}, index} ->
      {:ok, agent} =
        Agents.create_agent(
          ws_id,
          %{
            "kind" => "ai",
            "display_name" => name,
            "role_title" => role,
            "department" => dept,
            "status" => Enum.at(["active", "active", "busy", "active", "offline"], index),
            "presence_status" => "online",
            "ai_enabled" => true,
            "human_takeover_enabled" => true,
            "skills" => skills,
            "performance_score" => Enum.at([88, 92, 95, 86, 83], index),
            "avatar_config" => %{
              "preset" => "bot-#{index + 1}",
              "primary_color" => color,
              "accent_color" => "#7c5cff",
              "seat_index" => 5 + index
            }
          },
          tom_member
        )

      {name, agent}
    end)

  all_agents = Map.merge(human_agents, ai_agents)

  ## ---------- Projects ----------

  project_specs = [
    {"AI Dashboard Redesign", "Redesign the main dashboard to improve user experience, add new analytics widgets, and optimize performance.", "active", "high", 75, "meeting"},
    {"Mobile App Development", "Build the mobile application for iOS and Android platforms.", "active", "high", 60, "coding"},
    {"Marketing Website", "Create a new marketing website with modern design and animations.", "in_review", "medium", 90, "design"},
    {"AI Feature Expansion", "Plan and implement new AI features based on user feedback.", "planning", "medium", 30, "whiteboard"},
    {"Internal Tools Update", "Update internal tooling and automation scripts.", "on_hold", "low", 45, "office"}
  ]

  projects =
    Map.new(project_specs, fn {name, description, status, priority, progress, cover} ->
      {:ok, project} =
        Projects.create_project(
          ws_id,
          %{
            "name" => name,
            "description" => description,
            "status" => status,
            "priority" => priority,
            "progress_percent" => progress,
            "cover_kind" => cover,
            "start_at" => DateTime.add(DateTime.utc_now(), -20, :day),
            "due_at" => DateTime.add(DateTime.utc_now(), 25, :day)
          },
          tom_member
        )

      {name, project}
    end)

  dashboard_project = projects["AI Dashboard Redesign"]

  for name <- ["Ava Rodriguez", "Ethan Carter", "Noah Williams", "Sophia Bennett"] do
    Projects.add_member(dashboard_project, members[name].id)
    Projects.add_agent(dashboard_project, human_agents[name].id)
  end

  Projects.add_agent(dashboard_project, ai_agents["Data Analyst"].id)
  Projects.add_agent(projects["Mobile App Development"], human_agents["Ethan Carter"].id)
  Projects.add_agent(projects["Mobile App Development"], ai_agents["Code Review Agent"].id)
  Projects.add_agent(projects["Marketing Website"], human_agents["Sophia Bennett"].id)
  Projects.add_agent(projects["Marketing Website"], ai_agents["Marketing Assistant"].id)

  ## ---------- Tasks ----------

  task_specs = [
    # {title, description, status, priority, agent, project, progress, tags, due_in_hours}
    {"Market research analysis", "Analyze market trends and competitor strategies", "to_do", "high", "Data Analyst", "AI Feature Expansion", 0, ["Research"], 48},
    {"Create landing page wireframe", "Design wireframe for the new landing page", "to_do", "medium", "Ava Rodriguez", "Marketing Website", 0, ["Design"], 72},
    {"Competitor pricing analysis", "Collect and analyze competitor pricing data", "to_do", "medium", "Sophia Bennett", "AI Feature Expansion", 0, ["Research"], 96},
    {"Blog content ideation", "Generate ideas for upcoming blog posts", "to_do", "low", "Marketing Assistant", "Marketing Website", 0, ["Content"], 120},
    {"UI design system", "Create components and style guide for the platform interface", "in_progress", "high", "Ava Rodriguez", "AI Dashboard Redesign", 60, ["Design", "UI/UX"], 24},
    {"API integration", "Integrate payment gateway and user APIs", "in_progress", "high", "Ethan Carter", "Mobile App Development", 45, ["Development"], 30},
    {"User flow optimization", "Optimize user flow based on analytics", "in_progress", "medium", "Noah Williams", "AI Dashboard Redesign", 70, ["Design"], 48},
    {"Database schema update", "Update database schema for new features", "in_progress", "medium", "Ethan Carter", "Mobile App Development", 30, ["Development"], 60},
    {"Landing page design", "Review and finalize the landing page design", "in_review", "high", "Sophia Bennett", "Marketing Website", 90, ["Design"], 12},
    {"Content strategy", "Review content strategy and approve topics", "in_review", "medium", "Noah Williams", "Marketing Website", 75, ["Content"], 36},
    {"Security audit", "Review security implementation and dependencies", "in_review", "high", "Code Review Agent", "Mobile App Development", 50, ["Development"], 24},
    {"Client feedback", "Waiting for client feedback on design concepts", "waiting", "high", "Ava Rodriguez", "Marketing Website", 0, ["Feedback"], 48},
    {"Legal approval", "Waiting for legal team review and approval", "waiting", "medium", "Mason Lee", "Internal Tools Update", 0, ["Legal"], 72},
    {"API access", "Waiting for third-party API access credentials", "waiting", "low", "Ethan Carter", "Mobile App Development", 0, ["External"], 96},
    {"Project feedoff", "Initial project setup and requirement gathering", "completed", "medium", "Noah Williams", "AI Dashboard Redesign", 100, ["General"], -24},
    {"Team onboarding", "Onboard new AI agents to the workspace", "completed", "medium", "Noah Williams", "AI Dashboard Redesign", 100, ["General"], -48},
    {"Requirements document", "Create comprehensive requirements document", "completed", "high", "Sophia Bennett", "AI Dashboard Redesign", 100, ["Documentation"], -72},
    {"Technical specification", "Define technical architecture and specifications", "completed", "high", "Ethan Carter", "AI Dashboard Redesign", 100, ["Documentation"], -96},
    {"Weekly usage report", "Generate the weekly workspace usage report", "in_progress", "medium", "Reporting Agent", "Internal Tools Update", 40, ["Reporting"], 24},
    {"Support ticket triage", "Categorize and prioritize incoming support tickets", "in_progress", "urgent", "Customer Support Bot", "Internal Tools Update", 55, ["Support"], 8}
  ]

  tasks =
    Enum.map(task_specs, fn {title, description, status, priority, agent_name, project_name, progress, tags, due_in} ->
      agent = all_agents[agent_name]
      project = projects[project_name]

      {:ok, task} =
        Tasks.create_task(
          ws_id,
          %{
            "title" => title,
            "description" => description,
            "status" => status,
            "priority" => priority,
            "assigned_agent_id" => agent.id,
            "project_id" => project.id,
            "progress_percent" => progress,
            "tags" => tags,
            "due_at" => DateTime.add(DateTime.utc_now(), due_in, :hour)
          },
          tom_member
        )

      task
    end)

  ui_task = Enum.find(tasks, &(&1.title == "UI design system"))

  for {subtitle, done} <- [
        {"Create color palette", true},
        {"Design typography scale", true},
        {"Build component library", true},
        {"Create style guide", false},
        {"Review with team", false}
      ] do
    {:ok, _} = Tasks.create_subtask(ui_task, %{"title" => subtitle, "done" => done})
  end

  {:ok, _} =
    Tasks.create_comment(
      ui_task,
      %{"body" => "Great progress on the component library! Let's sync on the style guide tomorrow."},
      tom_member
    )

  ## ---------- Knowledge ----------

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

  categories =
    Map.new(category_specs, fn {name, color} ->
      {:ok, category} = Knowledge.create_category(ws_id, %{"name" => name, "color" => color})
      {name, category}
    end)

  knowledge_specs = [
    {"Employee Onboarding Guide", "document", "HR", "published", ["onboarding", "hr", "process"]},
    {"Product Roadmap 2026", "document", "Products", "published", ["roadmap", "planning"]},
    {"Pricing Strategy", "document", "Sales", "published", ["pricing", "strategy"]},
    {"Brand Guidelines", "file", "Marketing", "published", ["brand", "design"]},
    {"API Documentation", "link", "Technical", "published", ["api", "docs"]},
    {"Company OKRs 2026", "document", "Company", "published", ["okr", "goals"]},
    {"Security Policy", "document", "Legal", "processing", ["security", "policy"]},
    {"Competitor Analysis", "document", "Marketing", "published", ["research"]},
    {"Q2 Sales Playbook", "document", "Sales", "published", ["sales", "playbook"]},
    {"Finance Report - June", "file", "Finance", "draft", ["finance", "report"]}
  ]

  for {title, type, category_name, status, tags} <- knowledge_specs do
    {:ok, item} =
      Knowledge.create_item(
        ws_id,
        %{
          "title" => title,
          "type" => type,
          "category_id" => categories[category_name].id,
          "status" => status,
          "tags" => tags,
          "source_url" => if(type == "link", do: "https://docs.mokaid.dev/api", else: nil),
          "body" =>
            if(type == "document",
              do: "This is the #{title} demo content used by AI agents when permitted.",
              else: nil
            ),
          "indexing_status" => if(status == "published", do: "indexed", else: "not_indexed"),
          "metadata" => %{
            "used_by_agent_ids" =>
              all_agents |> Map.values() |> Enum.take_random(3) |> Enum.map(& &1.id),
            "file_size_bytes" => if(type == "file", do: 2_400_000, else: nil)
          }
        },
        tom_member
      )

    if status == "published", do: Knowledge.mark_indexed(item)
  end

  ## ---------- Drive extras ----------

  shared = Drive.ensure_system_folder(ws_id, "Shared")
  _uploads = Drive.ensure_system_folder(ws_id, "Uploads")
  agents_root = Drive.ensure_system_folder(ws_id, "Agents")

  for {_name, agent} <- ai_agents do
    {:ok, agent_folder} =
      Drive.create_folder(ws_id, %{
        "name" => agent.display_name,
        "parent_id" => agents_root.id,
        "linked_agent_id" => agent.id,
        "is_system_folder" => true
      })

    for sub <- ["Generated Outputs", "Working Files", "Training Docs"] do
      {:ok, _} =
        Drive.create_folder(ws_id, %{
          "name" => sub,
          "parent_id" => agent_folder.id,
          "linked_agent_id" => agent.id,
          "is_system_folder" => true
        })
    end
  end

  {:ok, _} =
    Drive.create_file(
      ws_id,
      %{
        "name" => "Brand Guidelines.pdf",
        "parent_id" => shared.id,
        "mime_type" => "application/pdf",
        "extension" => "pdf",
        "size_bytes" => 2_400_000,
        "storage_key" => "demo/brand-guidelines.pdf",
        "is_ai_readable" => true,
        "tags" => ["brand", "design"]
      },
      tom_member
    )

  {:ok, _} =
    Drive.create_file(
      ws_id,
      %{
        "name" => "Q2 Report.xlsx",
        "parent_id" => shared.id,
        "mime_type" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "extension" => "xlsx",
        "size_bytes" => 890_000,
        "storage_key" => "demo/q2-report.xlsx",
        "tags" => ["finance"]
      },
      tom_member
    )

  ## ---------- Calendar ----------

  today = DateTime.utc_now()

  calendar_specs = [
    {"Stand up meeting", "meeting", 0, 9, 30},
    {"Design Landing Page", "schedule", 0, 10, 120},
    {"Review & Feedback", "meeting", 0, 14, 60},
    {"UX Research", "schedule", 0, 16, 90},
    {"Sprint planning", "meeting", 1, 10, 60},
    {"Product demo", "meeting", 2, 15, 45},
    {"Marketing sync", "meeting", 3, 11, 30}
  ]

  for {title, kind, day_offset, hour, duration_min} <- calendar_specs do
    start_at =
      today
      |> DateTime.add(day_offset, :day)
      |> DateTime.to_date()
      |> DateTime.new!(Time.new!(hour, 0, 0))

    {:ok, _} =
      Calendar.create_event(ws_id, %{
        "title" => title,
        "kind" => kind,
        "start_at" => start_at,
        "end_at" => DateTime.add(start_at, duration_min * 60, :second)
      })
  end

  ## ---------- Leave requests ----------

  {:ok, vacation} =
    Members.create_leave_request(ws_id, Repo.preload(members["Ava Rodriguez"], :linked_agent), %{
      "type" => "vacation",
      "start_at" => DateTime.add(today, 14, :day),
      "end_at" => DateTime.add(today, 19, :day),
      "reason" => "Family trip"
    })

  {:ok, _} = Members.review_leave_request(vacation, "approved", tom_member)

  {:ok, _} =
    Members.create_leave_request(ws_id, Repo.preload(members["Mason Lee"], :linked_agent), %{
      "type" => "remote_work",
      "start_at" => DateTime.add(today, 2, :day),
      "end_at" => DateTime.add(today, 4, :day),
      "reason" => "Working from home office"
    })

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
    {"microsoft_teams", "Microsoft Teams", "Communication", "Notifications and team collaboration."},
    {"dropbox", "Dropbox", "Storage", "Cloud storage and file sharing."},
    {"stripe", "Stripe", "Finance", "Payments and billing."},
    {"jira", "Jira", "Project Management", "Issue tracking and agile boards."},
    {"linear", "Linear", "Project Management", "Modern issue tracking."},
    {"google_calendar", "Google Calendar", "Productivity", "Sync events and schedules."}
  ]

  for {key, name, category, description} <- provider_specs do
    Repo.insert!(
      %IntegrationProvider{key: key, name: name, category: category, description: description},
      on_conflict: :nothing
    )
  end

  for key <- ["slack", "google_drive", "gmail", "notion", "github"] do
    {:ok, _} = Mokaid.Integrations.connect(ws_id, key, tom_member)
  end

  ## ---------- Billing ----------

  business_plan =
    Repo.insert!(
      %BillingPlan{
        key: "business",
        name: "Business Plan",
        price_cents_monthly: 11_900,
        price_cents_yearly: 118_800,
        limits: %{
          "agents" => 50,
          "ai_requests_monthly" => 50_000,
          "storage_gb" => 100,
          "automations_monthly" => 5_000,
          "api_calls_monthly" => 200_000
        },
        features: [
          "Up to 50 agents",
          "50,000 AI requests / month",
          "100 GB storage",
          "5,000 automations / month",
          "Priority support",
          "Advanced analytics",
          "Custom integrations"
        ]
      },
      on_conflict: :nothing
    )

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

  for {number, days_ago} <- [{"INV-2026-0056", 15}, {"INV-2026-0042", 45}, {"INV-2026-0030", 75}] do
    Repo.insert!(%Invoice{
      workspace_id: ws_id,
      number: number,
      status: "paid",
      amount_cents: 9_900,
      currency: "USD",
      issued_at: DateTime.add(today, -days_ago, :day),
      paid_at: DateTime.add(today, -days_ago + 2, :day),
      line_items: [%{"description" => "Business Plan — monthly", "amount_cents" => 9_900}]
    })
  end

  ## ---------- Usage events ----------

  agent_ids = all_agents |> Map.values() |> Enum.map(& &1.id)

  for day_offset <- 0..29 do
    occurred_at = DateTime.add(today, -day_offset, :day)

    for {event_type, unit, base} <- [
          {"ai_request", "request", 400},
          {"task_executed", "task", 20},
          {"api_call", "call", 2_500},
          {"automation_run", "run", 35},
          {"storage_used", "mb", 600}
        ] do
      quantity = base + :rand.uniform(div(base, 2))

      {:ok, _} =
        Billing.record_usage(
          ws_id,
          "agent",
          Enum.random(agent_ids),
          event_type,
          quantity,
          unit,
          cost_cents: if(event_type == "ai_request", do: div(quantity, 10), else: 0),
          metadata: %{}
        )
        |> then(fn {:ok, event} ->
          event
          |> Ecto.Changeset.change(occurred_at: occurred_at)
          |> Repo.update()
        end)
    end
  end

  Logger.info("Seed complete: workspace=#{ws_id}")
  Logger.info("Login: tom@mokaid.dev / mokaid-dev-1234")
end
