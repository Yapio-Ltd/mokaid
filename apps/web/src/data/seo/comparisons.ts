import type { FaqItem } from "@/lib/seo";

export interface ComparisonRow {
  dimension: string;
  mokaid: string;
  competitor: string;
}

export interface Comparison {
  slug: string;
  competitor: string;
  title: string;
  metaDescription: string;
  h1: string;
  intro: string;
  competitorSummary: string;
  rows: ComparisonRow[];
  chooseCompetitor: string;
  chooseMokaid: string;
  faq: FaqItem[];
}

export const comparisons: Comparison[] = [
  {
    slug: "mokaid-vs-lindy",
    competitor: "Lindy",
    title: "mokaid vs Lindy (2026) — AI Employees Compared",
    metaDescription:
      "mokaid vs Lindy: visual AI workforce in a 3D office vs no-code AI assistant workflows. An honest comparison to help you pick the right platform.",
    h1: "mokaid vs Lindy: a visible AI workforce vs no-code AI assistants",
    intro:
      "Lindy and mokaid both let you put AI to work on real business tasks, but they come from different philosophies. Lindy is a polished no-code builder for AI assistants and workflows. mokaid is an AI Workforce OS: role-based AI employees with identities, task queues, and a real-time 3D office where you watch them work.",
    competitorSummary:
      "Lindy is a no-code platform for building AI assistants ('Lindies') that automate personal and team operations — inbox management, scheduling, meeting notes — with a large integration library and a freemium model. It is one of the most user-friendly tools in the category.",
    rows: [
      {
        dimension: "Core model",
        mokaid: "Role-based AI employees with persistent identity and task ownership",
        competitor: "Task-based AI assistants built from workflow triggers",
      },
      {
        dimension: "Visibility",
        mokaid: "Real-time 3D office — see every AI employee and what it is working on",
        competitor: "Dashboard and run logs",
      },
      {
        dimension: "Management model",
        mokaid: "Tasks, approval gates, reviews — manage AI like a team",
        competitor: "Configure and monitor workflows",
      },
      {
        dimension: "Collaboration between AI workers",
        mokaid: "AI employees hand off tasks and share knowledge in one workspace",
        competitor: "Lindies can chain, orchestration is workflow-level",
      },
      {
        dimension: "Best for",
        mokaid: "Teams building a durable AI workforce across functions",
        competitor: "Individuals and small teams automating personal ops",
      },
    ],
    chooseCompetitor:
      "Choose Lindy if you mainly want a personal AI assistant for inbox, calendar, and meeting workflows, and you like assembling automations yourself from triggers and actions.",
    chooseMokaid:
      "Choose mokaid if you want AI to hold jobs, not just run workflows: persistent AI employees with roles, queues, and governance, managed the way you manage people — with the unique advantage that you can see your whole AI workforce working in one 3D office.",
    faq: [
      {
        question: "Can mokaid do the personal-assistant tasks Lindy is known for?",
        answer:
          "Yes — mokaid's AI executive assistant covers inbox triage, scheduling, and follow-ups. The difference is that it exists as a persistent teammate in your office rather than a set of workflows.",
      },
      {
        question: "Which is easier to start with?",
        answer:
          "Both onboard in minutes. Lindy starts from workflow templates; mokaid starts by hiring a role — you pick an AI employee, connect its tools, and give it work.",
      },
    ],
  },
  {
    slug: "mokaid-vs-artisan",
    competitor: "Artisan",
    title: "mokaid vs Artisan (2026) — Beyond the AI BDR",
    metaDescription:
      "mokaid vs Artisan: a full AI workforce in a visible 3D office vs a specialized AI BDR for outbound sales. Honest comparison for 2026 buyers.",
    h1: "mokaid vs Artisan: a whole AI workforce vs one AI BDR",
    intro:
      "Artisan built its brand on Ava, an AI BDR that runs outbound prospecting end to end. mokaid takes a broader view: sales is one desk in your office. If outbound is your only problem, compare the point solutions; if you are building an AI-powered company, compare the operating systems.",
    competitorSummary:
      "Artisan is a well-funded AI sales platform centered on Ava, an AI business development rep that sources leads from a large B2B contact database, writes personalized outreach, and manages deliverability. It is enterprise-priced and focused exclusively on outbound.",
    rows: [
      {
        dimension: "Scope",
        mokaid: "Full AI workforce: sales, support, content, engineering, ops",
        competitor: "Outbound sales (AI BDR)",
      },
      {
        dimension: "Visibility",
        mokaid: "Watch your AI SDR work alongside other AI employees in a 3D office",
        competitor: "Campaign dashboards and reports",
      },
      {
        dimension: "Human control",
        mokaid: "Per-message approval gates, loosened as trust builds",
        competitor: "Campaign-level configuration and review",
      },
      {
        dimension: "Data",
        mokaid: "Works with your CRM and data sources via MCP connectors",
        competitor: "Built-in B2B contact database (a genuine strength)",
      },
      {
        dimension: "Pricing model",
        mokaid: "Self-serve, start free, scale by workforce size",
        competitor: "Enterprise sales process, annual contracts",
      },
    ],
    chooseCompetitor:
      "Choose Artisan if outbound is your single bottleneck, you want a built-in contact database, and you have the budget and patience for an enterprise platform dedicated to prospecting.",
    chooseMokaid:
      "Choose mokaid if you want outbound and the rest of the work handled by one governed AI workforce — an AI SDR that coordinates with your AI marketer and support agent in a workspace you can actually see, at self-serve pricing.",
    faq: [
      {
        question: "Does mokaid include a B2B contact database?",
        answer:
          "No — mokaid connects to your existing data sources and prospecting tools rather than bundling a database. Your AI SDR works with the systems you already trust.",
      },
      {
        question: "Can mokaid's AI SDR match a dedicated AI BDR tool?",
        answer:
          "For research, personalization, sequencing, and CRM hygiene, yes — with tighter human control via approval gates. Teams that need embedded contact data pair mokaid with their existing data provider.",
      },
    ],
  },
  {
    slug: "mokaid-vs-11x",
    competitor: "11x",
    title: "mokaid vs 11x (2026) — Digital Workers Compared",
    metaDescription:
      "mokaid vs 11x: self-serve visual AI workforce vs enterprise AI sales workers. See how the platforms differ on scope, control, and transparency.",
    h1: "mokaid vs 11x: visible AI employees vs enterprise digital workers",
    intro:
      "11x popularized the 'digital worker' framing with Alice (AI SDR) and Julian (AI phone agent) for enterprise sales teams. mokaid shares the conviction that AI should hold jobs — and adds the missing piece: a workforce you can see, govern, and grow across every function, not just revenue.",
    competitorSummary:
      "11x is an enterprise platform selling AI sales workers — an AI SDR for multi-channel outbound and an AI phone agent for calls. It targets teams that want to augment or replace parts of their SDR function, sold through an enterprise sales process without self-serve.",
    rows: [
      {
        dimension: "Scope",
        mokaid: "Cross-functional AI workforce: 8+ roles from sales to engineering",
        competitor: "Sales-focused digital workers (SDR, phone)",
      },
      {
        dimension: "Transparency",
        mokaid: "Live 3D office plus full audit trail of every action",
        competitor: "Enterprise dashboards",
      },
      {
        dimension: "Buying process",
        mokaid: "Self-serve, free to start",
        competitor: "Sales-led, no public pricing",
      },
      {
        dimension: "Governance",
        mokaid: "Approval gates and per-employee permissions, configurable by you",
        competitor: "Enterprise-grade controls configured with vendor",
      },
      {
        dimension: "Best for",
        mokaid: "Startups to mid-market building an AI-native org",
        competitor: "Enterprise revenue teams with procurement budgets",
      },
    ],
    chooseCompetitor:
      "Choose 11x if you are an enterprise revenue organization that wants vendor-managed AI sales workers, including AI phone calls, and prefers a sales-led relationship.",
    chooseMokaid:
      "Choose mokaid if you want to evaluate today without a sales call, need AI employees beyond sales, and believe a workforce you can watch working is easier to trust and manage than one behind a dashboard.",
    faq: [
      {
        question: "Does mokaid make AI phone calls?",
        answer:
          "mokaid's AI employees work across text-based channels — email, chat, docs, code, tickets. Voice is not the core focus; teams that need AI calling typically pair mokaid with a dedicated voice tool.",
      },
    ],
  },
  {
    slug: "mokaid-vs-sintra",
    competitor: "Sintra",
    title: "mokaid vs Sintra (2026) — AI Helpers vs AI Employees",
    metaDescription:
      "mokaid vs Sintra: governed, visible AI employees in a 3D office vs a marketplace of pre-built AI helpers. Which fits your business in 2026?",
    h1: "mokaid vs Sintra: an AI workforce OS vs a pack of AI helpers",
    intro:
      "Sintra offers a friendly cast of pre-configured AI helpers for marketing and business growth. mokaid targets the step beyond helpers: AI employees with real task ownership, real tool access, real governance — and a 3D office that makes the whole workforce legible at a glance.",
    competitorSummary:
      "Sintra provides a marketplace of pre-built AI assistants ('helpers') focused on marketing, sales, and small-business growth, each with a persona and specialty. It is popular with solopreneurs and small teams for its approachable, template-driven experience.",
    rows: [
      {
        dimension: "Depth of autonomy",
        mokaid: "AI employees own outcomes: queues, follow-through, reporting",
        competitor: "Helpers assist on prompted tasks and playbooks",
      },
      {
        dimension: "Tool access",
        mokaid: "OAuth into your real stack via MCP connectors, with audit logs",
        competitor: "Focused on marketing and CRM stacks",
      },
      {
        dimension: "Governance",
        mokaid: "Approval gates, permissions, audit trail per employee",
        competitor: "Lightweight, persona-level settings",
      },
      {
        dimension: "Visibility",
        mokaid: "Real-time 3D office showing who works on what",
        competitor: "Chat-style interface per helper",
      },
      {
        dimension: "Best for",
        mokaid: "Teams ready to delegate outcomes to a governed AI workforce",
        competitor: "Solopreneurs wanting quick, guided marketing help",
      },
    ],
    chooseCompetitor:
      "Choose Sintra if you want inexpensive, personality-driven AI helpers for guided marketing tasks and you prefer prompting over delegating.",
    chooseMokaid:
      "Choose mokaid if you are past prompting: you want AI teammates that hold roles, work autonomously under your gates, coordinate with each other, and remain fully visible in one office view.",
    faq: [
      {
        question: "Is mokaid harder to set up than Sintra?",
        answer:
          "Hiring an AI employee takes minutes either way. mokaid asks slightly more up front — connecting real tools and defining approval gates — because its employees do real work in your systems rather than producing suggestions in a chat window.",
      },
    ],
  },
];

export function getComparison(slug: string): Comparison | undefined {
  return comparisons.find((c) => c.slug === slug);
}
