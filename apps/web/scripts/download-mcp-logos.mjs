#!/usr/bin/env node
/**
 * Downloads brand SVG logos for the MCP Hub catalog from Simple Icons
 * (https://cdn.simpleicons.org) into public/logos/mcp/.
 *
 * Brands missing from Simple Icons are skipped — the UI falls back to
 * colored initials. Run: node scripts/download-mcp-logos.mjs
 */

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const slugs = [
  "googledrive", "gmail", "googlecalendar", "googledocs", "googlesheets",
  "microsoft365", "microsoftoutlook", "microsoftonedrive", "dropbox", "box",
  "notion", "confluence", "obsidian",
  "github", "gitlab", "bitbucket", "jira", "linear", "azuredevops", "sentry",
  "postman", "docker", "kubernetes", "terraform",
  "slack", "discord", "microsoftteams", "telegram", "whatsapp", "twilio",
  "zoom", "googlemeet",
  "hubspot", "salesforce", "pipedrive", "zoho", "mondaydotcom", "clickup",
  "asana", "trello",
  "stripe", "quickbooks", "xero", "pennylane", "shopify", "square", "paypal",
  "amazonwebservices", "cloudflare", "vercel", "netlify", "digitalocean",
  "microsoftazure", "googlecloud",
  "postgresql", "mysql", "mongodb", "redis", "supabase", "neon", "planetscale",
  "snowflake",
  "openai", "anthropic", "googlegemini", "mistralai", "groq", "togetherdotai",
  "replicate", "huggingface",
  "brave", "tavily", "exa", "serpapi", "firecrawl",
  "playwright", "browserbase", "browseruse", "puppeteer",
  "figma", "canva", "adobe",
  "readme", "gitbook", "docusaurus",
  "amazons3",
  "grafana", "prometheus", "datadog", "newrelic", "amazoncloudwatch",
];

const outDir = join(dirname(fileURLToPath(import.meta.url)), "..", "public", "logos", "mcp");
await mkdir(outDir, { recursive: true });

// Some brands were removed from recent Simple Icons releases (trademark
// policy); simple-icons@9 on jsdelivr still ships them. Map catalog slug ->
// v9 slug where they differ.
const legacyAliases = {
  amazonwebservices: "amazonaws",
  microsoft365: "microsoftoffice",
};

let ok = 0;
const missing = [];

for (const slug of slugs) {
  try {
    // "white" keeps logos legible on the dark UI.
    const res = await fetch(`https://cdn.simpleicons.org/${slug}/white`);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const svg = await res.text();
    await writeFile(join(outDir, `${slug}.svg`), svg);
    ok += 1;
  } catch {
    try {
      const legacy = legacyAliases[slug] ?? slug;
      const res = await fetch(`https://cdn.jsdelivr.net/npm/simple-icons@9/icons/${legacy}.svg`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const svg = (await res.text()).replace("<svg ", '<svg fill="#ffffff" ');
      await writeFile(join(outDir, `${slug}.svg`), svg);
      ok += 1;
    } catch {
      missing.push(slug);
    }
  }
}

console.log(`Downloaded ${ok}/${slugs.length} logos to public/logos/mcp/`);
if (missing.length) console.log(`Missing (fallback to initials): ${missing.join(", ")}`);
