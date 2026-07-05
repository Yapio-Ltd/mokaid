defmodule Mokaid.MCP.Catalog do
  @moduledoc """
  Static catalog of installable MCP servers, seeded into `mcp_servers`.

  `server_url` is set for providers with a known hosted (remote) MCP server;
  the rest are connectable through an API key or a custom MCP server URL.
  `logo_slug` targets Simple Icons (cdn.simpleicons.org); the frontend falls
  back to colored initials when a brand has no icon.
  """

  # {key, name, category, description, logo_slug, featured, auth_kind, server_url}
  @entries [
    # ---------- Productivity ----------
    {"google_drive", "Google Drive", "productivity",
     "Browse, read and manage files in Google Drive.", "googledrive", false, "oauth2", nil},
    {"gmail", "Gmail", "productivity", "Read, draft and send email through Gmail.", "gmail",
     false, "oauth2", nil},
    {"google_calendar", "Google Calendar", "productivity",
     "Read and manage calendar events and availability.", "googlecalendar", false, "oauth2", nil},
    {"google_docs", "Google Docs", "productivity", "Create and edit documents in Google Docs.",
     "googledocs", false, "oauth2", nil},
    {"google_sheets", "Google Sheets", "productivity",
     "Read and write spreadsheet data in Google Sheets.", "googlesheets", false, "oauth2", nil},
    {"microsoft_365", "Microsoft 365", "productivity",
     "Work with Word, Excel and PowerPoint documents.", "microsoft365", false, "oauth2", nil},
    {"outlook", "Outlook", "productivity", "Read, draft and send email through Outlook.",
     "microsoftoutlook", false, "oauth2", nil},
    {"onedrive", "OneDrive", "productivity", "Browse and manage files stored in OneDrive.",
     "microsoftonedrive", false, "oauth2", nil},
    {"dropbox", "Dropbox", "productivity", "Access and organize files stored in Dropbox.",
     "dropbox", false, "api_key", nil},
    {"box", "Box", "productivity", "Access and manage enterprise content in Box.", "box", false,
     "api_key", nil},
    {"notion", "Notion", "productivity", "Search, read and write Notion pages and databases.",
     "notion", true, "oauth2", "https://mcp.notion.com/mcp"},
    {"confluence", "Confluence", "productivity", "Search and edit Confluence pages and spaces.",
     "confluence", false, "api_key", "https://mcp.atlassian.com/v1/sse"},
    {"obsidian", "Obsidian", "productivity", "Read and write notes in an Obsidian vault.",
     "obsidian", false, "custom", nil},

    # ---------- Development ----------
    {"github", "GitHub", "development", "Repositories, issues, pull requests and code search.",
     "github", true, "api_key", "https://api.githubcopilot.com/mcp/"},
    {"gitlab", "GitLab", "development", "Projects, merge requests, issues and CI pipelines.",
     "gitlab", false, "api_key", nil},
    {"bitbucket", "Bitbucket", "development", "Repositories, pull requests and pipelines.",
     "bitbucket", false, "api_key", nil},
    {"jira", "Jira", "development", "Search, create and update Jira issues and boards.", "jira",
     false, "api_key", "https://mcp.atlassian.com/v1/sse"},
    {"linear", "Linear", "development", "Create and manage Linear issues, projects and cycles.",
     "linear", true, "api_key", "https://mcp.linear.app/mcp"},
    {"azure_devops", "Azure DevOps", "development",
     "Work items, repos and pipelines in Azure DevOps.", "azuredevops", false, "api_key", nil},
    {"sentry", "Sentry", "development", "Query errors, issues and performance data from Sentry.",
     "sentry", false, "api_key", "https://mcp.sentry.dev/mcp"},
    {"postman", "Postman", "development", "Run collections and manage APIs in Postman.",
     "postman", false, "api_key", nil},
    {"docker", "Docker", "development", "Manage containers, images and compose stacks.", "docker",
     false, "custom", nil},
    {"kubernetes", "Kubernetes", "development",
     "Inspect and manage Kubernetes clusters and workloads.", "kubernetes", false, "custom", nil},
    {"terraform", "Terraform", "development",
     "Plan and inspect infrastructure as code with Terraform.", "terraform", false, "custom",
     nil},

    # ---------- Communication ----------
    {"slack", "Slack", "communication", "Send messages, search history and manage channels.",
     "slack", true, "oauth2", nil},
    {"discord", "Discord", "communication", "Send messages and manage Discord servers.",
     "discord", false, "api_key", nil},
    {"microsoft_teams", "Microsoft Teams", "communication",
     "Send messages and notifications to Teams channels.", "microsoftteams", false, "oauth2",
     nil},
    {"telegram", "Telegram", "communication", "Send and receive messages via Telegram bots.",
     "telegram", false, "api_key", nil},
    {"whatsapp_business", "WhatsApp Business", "communication",
     "Send messages through the WhatsApp Business API.", "whatsapp", false, "api_key", nil},
    {"twilio", "Twilio", "communication", "Send SMS and manage voice communications.", "twilio",
     false, "api_key", nil},
    {"zoom", "Zoom", "communication", "Schedule and manage Zoom meetings.", "zoom", false,
     "oauth2", nil},
    {"google_meet", "Google Meet", "communication", "Create and manage Google Meet meetings.",
     "googlemeet", false, "oauth2", nil},

    # ---------- CRM & project management ----------
    {"hubspot", "HubSpot", "crm", "Contacts, companies, deals and marketing automation.",
     "hubspot", true, "api_key", nil},
    {"salesforce", "Salesforce", "crm", "Query and update Salesforce CRM records.", "salesforce",
     false, "oauth2", nil},
    {"pipedrive", "Pipedrive", "crm", "Manage leads, deals and pipelines in Pipedrive.",
     "pipedrive", false, "api_key", nil},
    {"zoho_crm", "Zoho CRM", "crm", "Access and manage Zoho CRM data.", "zoho", false, "api_key",
     nil},
    {"monday", "Monday.com", "crm", "Boards, items and workflows in Monday.com.", "mondaydotcom",
     false, "api_key", "https://mcp.monday.com/sse"},
    {"clickup", "ClickUp", "crm", "Tasks, lists and spaces in ClickUp.", "clickup", false,
     "api_key", nil},
    {"asana", "Asana", "crm", "Tasks, projects and portfolios in Asana.", "asana", false,
     "oauth2", "https://mcp.asana.com/sse"},
    {"trello", "Trello", "crm", "Boards, cards and checklists in Trello.", "trello", false,
     "api_key", nil},

    # ---------- Finance ----------
    {"stripe", "Stripe", "finance", "Payments, customers, invoices and subscriptions.", "stripe",
     true, "api_key", "https://mcp.stripe.com"},
    {"quickbooks", "QuickBooks", "finance", "Accounting, invoices and expenses in QuickBooks.",
     "quickbooks", false, "oauth2", nil},
    {"xero", "Xero", "finance", "Accounting and invoicing data from Xero.", "xero", false,
     "oauth2", nil},
    {"pennylane", "Pennylane", "finance", "French accounting and financial management.",
     "pennylane", false, "api_key", nil},
    {"shopify", "Shopify", "finance", "Products, orders and customers of a Shopify store.",
     "shopify", false, "api_key", nil},
    {"square", "Square", "finance", "Payments, catalog and customers in Square.", "square", false,
     "api_key", "https://mcp.squareup.com/sse"},
    {"paypal", "PayPal", "finance", "Payments, invoices and disputes via PayPal.", "paypal",
     false, "api_key", "https://mcp.paypal.com/mcp"},

    # ---------- Cloud ----------
    {"aws", "AWS", "cloud", "Inspect and manage AWS resources and services.", "amazonwebservices",
     true, "api_key", nil},
    {"cloudflare", "Cloudflare", "cloud", "Workers, DNS, R2 and analytics on Cloudflare.",
     "cloudflare", false, "oauth2", "https://observability.mcp.cloudflare.com/sse"},
    {"vercel", "Vercel", "cloud", "Deployments, projects and domains on Vercel.", "vercel", false,
     "api_key", "https://mcp.vercel.com"},
    {"netlify", "Netlify", "cloud", "Sites, deploys and forms on Netlify.", "netlify", false,
     "api_key", nil},
    {"digitalocean", "DigitalOcean", "cloud", "Droplets, apps and databases on DigitalOcean.",
     "digitalocean", false, "api_key", nil},
    {"azure", "Azure", "cloud", "Inspect and manage Microsoft Azure resources.", "microsoftazure",
     false, "api_key", nil},
    {"gcp", "Google Cloud", "cloud", "Inspect and manage Google Cloud resources.", "googlecloud",
     false, "api_key", nil},

    # ---------- Databases ----------
    {"postgresql", "PostgreSQL", "database", "Query and inspect PostgreSQL databases.",
     "postgresql", false, "custom", nil},
    {"mysql", "MySQL", "database", "Query and inspect MySQL databases.", "mysql", false, "custom",
     nil},
    {"mongodb", "MongoDB", "database", "Query collections and documents in MongoDB.", "mongodb",
     false, "custom", nil},
    {"redis", "Redis", "database", "Inspect keys and run commands on Redis.", "redis", false,
     "custom", nil},
    {"supabase", "Supabase", "database", "Database, auth and storage on Supabase.", "supabase",
     false, "api_key", nil},
    {"neon", "Neon", "database", "Serverless Postgres branches and queries on Neon.", "neon",
     false, "api_key", "https://mcp.neon.tech/sse"},
    {"planetscale", "PlanetScale", "database", "Serverless MySQL databases on PlanetScale.",
     "planetscale", false, "api_key", nil},
    {"snowflake", "Snowflake", "database", "Query the Snowflake data warehouse.", "snowflake",
     false, "api_key", nil},

    # ---------- AI ----------
    {"openai", "OpenAI", "ai", "Call OpenAI models for generation and analysis.", "openai", false,
     "api_key", nil},
    {"anthropic", "Anthropic", "ai", "Call Claude models for generation and analysis.",
     "anthropic", false, "api_key", nil},
    {"gemini", "Gemini", "ai", "Call Google Gemini models.", "googlegemini", false, "api_key",
     nil},
    {"mistral", "Mistral", "ai", "Call Mistral models.", "mistralai", false, "api_key", nil},
    {"groq", "Groq", "ai", "Ultra-fast inference on Groq hardware.", "groq", false, "api_key",
     nil},
    {"together_ai", "Together AI", "ai", "Open-source model inference on Together AI.",
     "togetherdotai", false, "api_key", nil},
    {"replicate", "Replicate", "ai", "Run open-source models hosted on Replicate.", "replicate",
     false, "api_key", nil},
    {"hugging_face", "Hugging Face", "ai", "Models, datasets and Spaces on Hugging Face.",
     "huggingface", false, "api_key", "https://huggingface.co/mcp"},

    # ---------- Web search ----------
    {"brave_search", "Brave Search", "search", "Web search through the Brave Search API.",
     "brave", false, "api_key", nil},
    {"tavily", "Tavily", "search", "Search API optimized for AI agents.", "tavily", false,
     "api_key", nil},
    {"exa", "Exa", "search", "Neural web search built for AI agents.", "exa", true, "api_key",
     "https://mcp.exa.ai/mcp"},
    {"serpapi", "SerpAPI", "search", "Structured Google search results via SerpAPI.", "serpapi",
     false, "api_key", nil},
    {"firecrawl", "Firecrawl", "search", "Crawl and scrape any website into clean data.",
     "firecrawl", true, "api_key", nil},

    # ---------- Browser automation ----------
    {"playwright", "Playwright", "browser", "Drive a real browser: navigate, click, extract.",
     "playwright", true, "custom", nil},
    {"browserbase", "Browserbase", "browser", "Headless browsers in the cloud for agents.",
     "browserbase", true, "api_key", nil},
    {"browser_use", "Browser Use", "browser", "Autonomous browser agent for complex web tasks.",
     "browseruse", false, "custom", nil},
    {"puppeteer", "Puppeteer", "browser", "Automate Chrome with the Puppeteer toolkit.",
     "puppeteer", false, "custom", nil},

    # ---------- Design ----------
    {"figma", "Figma", "design", "Read designs, components and styles from Figma files.", "figma",
     true, "oauth2", "https://mcp.figma.com/mcp"},
    {"canva", "Canva", "design", "Create and manage designs in Canva.", "canva", false, "oauth2",
     "https://mcp.canva.com/mcp"},
    {"adobe_express", "Adobe Express", "design",
     "Quick designs and templates with Adobe Express.", "adobe", false, "oauth2", nil},

    # ---------- Documentation ----------
    {"readme", "ReadMe", "docs", "Manage API documentation hubs on ReadMe.", "readme", false,
     "api_key", nil},
    {"gitbook", "GitBook", "docs", "Read and update GitBook documentation spaces.", "gitbook",
     false, "api_key", nil},
    {"docusaurus", "Docusaurus", "docs", "Work with Docusaurus documentation sites.",
     "docusaurus", false, "custom", nil},

    # ---------- Storage ----------
    {"aws_s3", "AWS S3", "storage", "Read and write objects in S3 buckets.", "amazons3", false,
     "api_key", nil},
    {"cloudflare_r2", "Cloudflare R2", "storage", "Object storage on Cloudflare R2.",
     "cloudflare", false, "api_key", nil},

    # ---------- Monitoring ----------
    {"grafana", "Grafana", "monitoring", "Dashboards, alerts and data sources in Grafana.",
     "grafana", false, "api_key", nil},
    {"prometheus", "Prometheus", "monitoring", "Query metrics from Prometheus.", "prometheus",
     false, "custom", nil},
    {"datadog", "Datadog", "monitoring", "Metrics, monitors and logs from Datadog.", "datadog",
     false, "api_key", nil},
    {"new_relic", "New Relic", "monitoring", "Application performance data from New Relic.",
     "newrelic", false, "api_key", nil},
    {"cloudwatch", "CloudWatch", "monitoring", "AWS metrics, logs and alarms from CloudWatch.",
     "amazoncloudwatch", false, "api_key", nil}
  ]

  @spec entries() :: [map()]
  def entries do
    Enum.map(@entries, fn {key, name, category, description, logo_slug, featured, auth_kind,
                           server_url} ->
      %{
        "key" => key,
        "name" => name,
        "category" => category,
        "description" => description,
        "logo_slug" => logo_slug,
        "featured" => featured,
        "auth_kind" => auth_kind,
        "server_url" => server_url,
        "transport" => "http"
      }
    end)
  end
end
