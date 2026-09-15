import { useState } from "react";
import { cn } from "@/lib/cn";
import { mcpBrandColor } from "@/components/landing/mcp-brand-colors";

type Connector = {
  key: string;
  name: string;
  category: string;
  slug: string;
  /** Household brands — larger visual weight on the landing. */
  spotlight?: boolean;
};

/**
 * Mirror of `Mokaid.MCP.Catalog` for the public landing (no auth).
 * Keep in sync when the backend catalog changes.
 */
const connectors: Connector[] = [
  { key: "slack", name: "Slack", category: "communication", slug: "slack", spotlight: true },
  { key: "github", name: "GitHub", category: "development", slug: "github", spotlight: true },
  { key: "notion", name: "Notion", category: "productivity", slug: "notion", spotlight: true },
  { key: "figma", name: "Figma", category: "design", slug: "figma", spotlight: true },
  { key: "linear", name: "Linear", category: "development", slug: "linear", spotlight: true },
  {
    key: "google_drive",
    name: "Google Drive",
    category: "productivity",
    slug: "googledrive",
    spotlight: true,
  },
  { key: "gmail", name: "Gmail", category: "productivity", slug: "gmail", spotlight: true },
  { key: "stripe", name: "Stripe", category: "finance", slug: "stripe", spotlight: true },
  {
    key: "aws",
    name: "AWS",
    category: "cloud",
    slug: "amazonwebservices",
    spotlight: true,
  },
  { key: "hubspot", name: "HubSpot", category: "crm", slug: "hubspot", spotlight: true },
  { key: "discord", name: "Discord", category: "communication", slug: "discord", spotlight: true },
  {
    key: "salesforce",
    name: "Salesforce",
    category: "crm",
    slug: "salesforce",
    spotlight: true,
  },
  { key: "shopify", name: "Shopify", category: "finance", slug: "shopify", spotlight: true },
  { key: "openai", name: "OpenAI", category: "ai", slug: "openai", spotlight: true },
  { key: "anthropic", name: "Anthropic", category: "ai", slug: "anthropic", spotlight: true },
  { key: "docker", name: "Docker", category: "development", slug: "docker", spotlight: true },
  { key: "jira", name: "Jira", category: "development", slug: "jira", spotlight: true },
  {
    key: "cloudflare",
    name: "Cloudflare",
    category: "cloud",
    slug: "cloudflare",
    spotlight: true,
  },
  { key: "vercel", name: "Vercel", category: "cloud", slug: "vercel", spotlight: true },
  {
    key: "microsoft_teams",
    name: "Teams",
    category: "communication",
    slug: "microsoftteams",
    spotlight: true,
  },

  {
    key: "google_calendar",
    name: "Google Calendar",
    category: "productivity",
    slug: "googlecalendar",
  },
  { key: "google_docs", name: "Google Docs", category: "productivity", slug: "googledocs" },
  { key: "google_sheets", name: "Google Sheets", category: "productivity", slug: "googlesheets" },
  {
    key: "microsoft_365",
    name: "Microsoft 365",
    category: "productivity",
    slug: "microsoft365",
  },
  { key: "outlook", name: "Outlook", category: "productivity", slug: "microsoftoutlook" },
  { key: "onedrive", name: "OneDrive", category: "productivity", slug: "microsoftonedrive" },
  { key: "dropbox", name: "Dropbox", category: "productivity", slug: "dropbox" },
  { key: "box", name: "Box", category: "productivity", slug: "box" },
  { key: "confluence", name: "Confluence", category: "productivity", slug: "confluence" },
  { key: "obsidian", name: "Obsidian", category: "productivity", slug: "obsidian" },
  { key: "gitlab", name: "GitLab", category: "development", slug: "gitlab" },
  { key: "bitbucket", name: "Bitbucket", category: "development", slug: "bitbucket" },
  {
    key: "azure_devops",
    name: "Azure DevOps",
    category: "development",
    slug: "azuredevops",
  },
  { key: "sentry", name: "Sentry", category: "development", slug: "sentry" },
  { key: "postman", name: "Postman", category: "development", slug: "postman" },
  { key: "kubernetes", name: "Kubernetes", category: "development", slug: "kubernetes" },
  { key: "terraform", name: "Terraform", category: "development", slug: "terraform" },
  { key: "telegram", name: "Telegram", category: "communication", slug: "telegram" },
  { key: "whatsapp_business", name: "WhatsApp", category: "communication", slug: "whatsapp" },
  { key: "twilio", name: "Twilio", category: "communication", slug: "twilio" },
  { key: "zoom", name: "Zoom", category: "communication", slug: "zoom" },
  { key: "google_meet", name: "Google Meet", category: "communication", slug: "googlemeet" },
  { key: "pipedrive", name: "Pipedrive", category: "crm", slug: "pipedrive" },
  { key: "zoho_crm", name: "Zoho CRM", category: "crm", slug: "zoho" },
  { key: "monday", name: "Monday.com", category: "crm", slug: "mondaydotcom" },
  { key: "clickup", name: "ClickUp", category: "crm", slug: "clickup" },
  { key: "asana", name: "Asana", category: "crm", slug: "asana" },
  { key: "trello", name: "Trello", category: "crm", slug: "trello" },
  { key: "quickbooks", name: "QuickBooks", category: "finance", slug: "quickbooks" },
  { key: "xero", name: "Xero", category: "finance", slug: "xero" },
  { key: "pennylane", name: "Pennylane", category: "finance", slug: "pennylane" },
  { key: "square", name: "Square", category: "finance", slug: "square" },
  { key: "paypal", name: "PayPal", category: "finance", slug: "paypal" },
  { key: "netlify", name: "Netlify", category: "cloud", slug: "netlify" },
  { key: "digitalocean", name: "DigitalOcean", category: "cloud", slug: "digitalocean" },
  { key: "azure", name: "Azure", category: "cloud", slug: "microsoftazure" },
  { key: "gcp", name: "Google Cloud", category: "cloud", slug: "googlecloud" },
  { key: "postgresql", name: "PostgreSQL", category: "database", slug: "postgresql" },
  { key: "mysql", name: "MySQL", category: "database", slug: "mysql" },
  { key: "mongodb", name: "MongoDB", category: "database", slug: "mongodb" },
  { key: "redis", name: "Redis", category: "database", slug: "redis" },
  { key: "supabase", name: "Supabase", category: "database", slug: "supabase" },
  { key: "neon", name: "Neon", category: "database", slug: "neon" },
  { key: "planetscale", name: "PlanetScale", category: "database", slug: "planetscale" },
  { key: "snowflake", name: "Snowflake", category: "database", slug: "snowflake" },
  { key: "gemini", name: "Gemini", category: "ai", slug: "googlegemini" },
  { key: "mistral", name: "Mistral", category: "ai", slug: "mistralai" },
  { key: "groq", name: "Groq", category: "ai", slug: "groq" },
  { key: "together_ai", name: "Together AI", category: "ai", slug: "togetherdotai" },
  { key: "replicate", name: "Replicate", category: "ai", slug: "replicate" },
  { key: "hugging_face", name: "Hugging Face", category: "ai", slug: "huggingface" },
  { key: "brave_search", name: "Brave Search", category: "search", slug: "brave" },
  { key: "tavily", name: "Tavily", category: "search", slug: "tavily" },
  { key: "exa", name: "Exa", category: "search", slug: "exa" },
  { key: "serpapi", name: "SerpAPI", category: "search", slug: "serpapi" },
  { key: "firecrawl", name: "Firecrawl", category: "search", slug: "firecrawl" },
  { key: "playwright", name: "Playwright", category: "browser", slug: "playwright" },
  { key: "browserbase", name: "Browserbase", category: "browser", slug: "browserbase" },
  { key: "browser_use", name: "Browser Use", category: "browser", slug: "browseruse" },
  { key: "puppeteer", name: "Puppeteer", category: "browser", slug: "puppeteer" },
  { key: "canva", name: "Canva", category: "design", slug: "canva" },
  { key: "adobe_express", name: "Adobe Express", category: "design", slug: "adobe" },
  { key: "lovable", name: "Lovable", category: "design", slug: "lovable" },
  { key: "readme", name: "ReadMe", category: "docs", slug: "readme" },
  { key: "gitbook", name: "GitBook", category: "docs", slug: "gitbook" },
  { key: "docusaurus", name: "Docusaurus", category: "docs", slug: "docusaurus" },
  { key: "aws_s3", name: "AWS S3", category: "storage", slug: "amazons3" },
  { key: "cloudflare_r2", name: "Cloudflare R2", category: "storage", slug: "cloudflare" },
  { key: "grafana", name: "Grafana", category: "monitoring", slug: "grafana" },
  { key: "prometheus", name: "Prometheus", category: "monitoring", slug: "prometheus" },
  { key: "datadog", name: "Datadog", category: "monitoring", slug: "datadog" },
  { key: "new_relic", name: "New Relic", category: "monitoring", slug: "newrelic" },
  {
    key: "cloudwatch",
    name: "CloudWatch",
    category: "monitoring",
    slug: "amazoncloudwatch",
  },
];

const categoryTint: Record<string, string> = {
  productivity: "#fbbf24",
  development: "#60a5fa",
  communication: "#22d3ee",
  crm: "#f87171",
  finance: "#a3e635",
  cloud: "#818cf8",
  database: "#34d399",
  ai: "#c4b5fd",
  search: "#f472b6",
  browser: "#fb923c",
  design: "#e879f9",
  docs: "#2dd4bf",
  storage: "#94a3b8",
  monitoring: "#facc15",
};

function whiteLogoUrl(slug: string) {
  return `/logos/mcp/${slug}.svg`;
}

function ConnectorMark({ connector, size }: { connector: Connector; size: "lg" | "sm" }) {
  const [failed, setFailed] = useState(false);
  const brand = mcpBrandColor[connector.slug];
  const tint = categoryTint[connector.category] ?? "#a1a1aa";
  const dim = size === "lg" ? "h-8 w-8" : "h-5 w-5";
  const initials = connector.name
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0])
    .join("")
    .toUpperCase();

  if (failed) {
    return (
      <span
        className={cn(
          "flex items-center justify-center rounded-md font-semibold text-white",
          size === "lg" ? "h-9 w-9 text-[11px]" : "h-6 w-6 text-[9px]",
        )}
        style={{ backgroundColor: brand ?? tint }}
        aria-hidden
      >
        {initials}
      </span>
    );
  }

  // Dark brand marks → white glyph for contrast on the dark landing.
  if (brand === null || brand === undefined) {
    return (
      <img
        src={whiteLogoUrl(connector.slug)}
        alt=""
        aria-hidden
        loading="lazy"
        decoding="async"
        className={cn(
          dim,
          "object-contain opacity-90 transition-opacity duration-200 group-hover:opacity-100",
        )}
        onError={() => setFailed(true)}
      />
    );
  }

  // Color brands: tint the white Simple Icons glyph with the official hex.
  return (
    <span className={cn(dim, "relative shrink-0")} aria-hidden>
      <span
        className="absolute inset-0 opacity-95 transition-opacity duration-200 group-hover:opacity-100"
        style={{
          backgroundColor: brand,
          WebkitMaskImage: `url(${whiteLogoUrl(connector.slug)})`,
          maskImage: `url(${whiteLogoUrl(connector.slug)})`,
          WebkitMaskSize: "contain",
          maskSize: "contain",
          WebkitMaskRepeat: "no-repeat",
          maskRepeat: "no-repeat",
          WebkitMaskPosition: "center",
          maskPosition: "center",
        }}
      />
      {/* Hidden probe so missing SVGs fall back to initials */}
      <img
        src={whiteLogoUrl(connector.slug)}
        alt=""
        loading="lazy"
        decoding="async"
        className="pointer-events-none absolute h-0 w-0 opacity-0"
        onError={() => setFailed(true)}
      />
    </span>
  );
}

export function McpConnectors() {
  const spotlight = connectors.filter((c) => c.spotlight);
  const rest = connectors.filter((c) => !c.spotlight);

  return (
    <section id="connectors" className="relative bg-bg px-4 py-16 sm:px-5 sm:py-24">
      <div
        className="pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-border/60 to-transparent"
        aria-hidden
      />

      <div className="mx-auto max-w-5xl">
        <div data-reveal className="mb-8 max-w-lg sm:mb-12">
          <h2 className="mt-3 text-[1.65rem] font-bold tracking-tight sm:text-3xl md:text-[42px] md:leading-[1.12]">
            Every tool your agents can reach
          </h2>
          <p className="mt-4 text-sm leading-relaxed text-text-secondary md:text-base">
            {connectors.length} MCP connectors. The apps everyone knows, front and center — the full
            catalog right below.
          </p>
        </div>

        <ul
          data-reveal
          className="grid grid-cols-1 gap-x-2 gap-y-1 min-[380px]:grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5"
        >
          {spotlight.map((connector) => (
            <li key={connector.key}>
              <div className="group flex items-center gap-3 rounded-lg px-2.5 py-3 transition-colors duration-200 hover:bg-surface/40">
                <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-surface-raised/60 ring-1 ring-border/40 transition-[box-shadow,background-color] duration-200 group-hover:bg-surface-raised group-hover:ring-border/70">
                  <ConnectorMark connector={connector} size="lg" />
                </span>
                <span className="min-w-0">
                  <span className="block truncate text-[14px] font-medium tracking-tight text-text transition-colors duration-200 group-hover:text-primary-light">
                    {connector.name}
                  </span>
                  <span className="mt-0.5 block text-[11px] capitalize text-text-muted">
                    {connector.category.replace("_", " ")}
                  </span>
                </span>
              </div>
            </li>
          ))}
        </ul>

        <div data-reveal className="mt-10 mb-6 flex items-center gap-4">
          <div className="h-px flex-1 bg-border/40" />
          <p className="shrink-0 text-[11px] font-semibold uppercase tracking-[0.18em] text-text-muted">
            + {rest.length} more
          </p>
          <div className="h-px flex-1 bg-border/40" />
        </div>

        <ul
          data-reveal
          className="grid grid-cols-4 gap-1 min-[400px]:grid-cols-5 sm:grid-cols-7 md:grid-cols-9 lg:grid-cols-12"
        >
          {rest.map((connector) => (
            <li key={connector.key}>
              <div
                title={connector.name}
                aria-label={connector.name}
                className="group flex items-center justify-center rounded-lg py-3 transition-colors duration-200 hover:bg-surface/40"
              >
                <span className="flex h-7 w-7 items-center justify-center opacity-70 transition-[opacity,transform] duration-200 group-hover:scale-110 group-hover:opacity-100">
                  <ConnectorMark connector={connector} size="sm" />
                </span>
              </div>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
