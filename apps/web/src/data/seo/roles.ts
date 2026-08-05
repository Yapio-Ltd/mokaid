import type { FaqItem } from "@/lib/seo";

export interface Role {
  slug: string;
  shortName: string;
  /** <title> tag, <=60 chars */
  title: string;
  metaDescription: string;
  h1: string;
  intro: string;
  /** One-sentence, quotable definition for GEO / featured snippets. */
  definition: string;
  responsibilities: string[];
  integrations: string[];
  outcomes: string[];
  faq: FaqItem[];
}

export const roles: Role[] = [
  {
    slug: "ai-sdr",
    shortName: "AI SDR",
    title: "AI SDR — Hire an AI Sales Development Rep | mokaid",
    metaDescription:
      "Hire an AI SDR that researches prospects, writes personalized outreach, and books meetings — and watch it work at its desk in mokaid's 3D virtual office.",
    h1: "Hire an AI SDR you can actually see working",
    intro:
      "Most AI SDR tools are black boxes: campaigns run somewhere in the cloud and you find out what happened from a weekly report. In mokaid, your AI sales development rep has a desk in your virtual office. You watch it research accounts, draft outreach, and queue follow-ups in real time — and every email can pass through an approval gate before it leaves the building.",
    definition:
      "An AI SDR is an autonomous AI employee that owns top-of-funnel sales work — prospect research, personalized outreach, follow-up sequences, and meeting booking — under human-defined guardrails.",
    responsibilities: [
      "Research target accounts and build prospect shortlists from your ICP",
      "Draft personalized first-touch emails and follow-up sequences",
      "Qualify inbound replies and route hot leads to a human closer",
      "Keep your CRM updated with every touch and outcome",
      "Report pipeline activity daily in plain language",
    ],
    integrations: ["Gmail", "Slack", "Notion", "HubSpot via MCP", "Linear"],
    outcomes: [
      "Consistent outbound volume without hiring a full SDR team",
      "Every message reviewable before send with approval gates",
      "Full audit trail of who was contacted, when, and why",
    ],
    faq: [
      {
        question: "Does the AI SDR send emails without my approval?",
        answer:
          "Only if you let it. mokaid's approval gates let you review every outbound message before it is sent. As trust builds, you can loosen the gate to review-by-exception or full autonomy per campaign.",
      },
      {
        question: "How is this different from tools like Artisan or 11x?",
        answer:
          "Artisan and 11x run sales campaigns behind a dashboard. mokaid gives your AI SDR a visible presence in a 3D office alongside your other AI employees, shared knowledge, task management, and human-in-the-loop controls — one workforce, not a point tool.",
      },
      {
        question: "Can the AI SDR work with my existing CRM and email?",
        answer:
          "Yes. It connects to Gmail and popular CRMs through mokaid's MCP connectors, reads and writes like a teammate, and logs every action for audit.",
      },
    ],
  },
  {
    slug: "ai-marketer",
    shortName: "AI Marketer",
    title: "AI Marketing Employee — Hire an AI Marketer | mokaid",
    metaDescription:
      "Hire an AI marketing employee that plans campaigns, writes copy, and reports results — visible at work in mokaid's 3D virtual office, with human approval gates.",
    h1: "An AI marketer that plans, writes, and ships — in plain sight",
    intro:
      "Marketing is a stream of small, compounding tasks: briefs, posts, emails, landing copy, reporting. A mokaid AI marketing employee owns that stream end to end. It sits at its desk in your virtual office, works through its task queue, and raises its hand when it needs a decision from you.",
    definition:
      "An AI marketing employee is an autonomous AI worker that owns recurring marketing execution — campaign planning, content drafting, channel posting, and performance reporting — as a persistent role on your team.",
    responsibilities: [
      "Turn goals into campaign briefs and content calendars",
      "Draft blog posts, newsletters, landing copy, and social posts in your brand voice",
      "Repurpose long-form content across channels",
      "Track performance and summarize what worked each week",
      "Coordinate with your AI SDR and AI content writer on shared campaigns",
    ],
    integrations: ["Notion", "Slack", "Gmail", "Figma", "Google Drive"],
    outcomes: [
      "A consistent publishing cadence without agency overhead",
      "Brand voice enforced through trained knowledge bases",
      "Weekly reporting you can read in two minutes",
    ],
    faq: [
      {
        question: "Will the AI marketer match our brand voice?",
        answer:
          "You train it on your docs, past content, and style guides through mokaid's knowledge system. Drafts then go through approval gates until you are satisfied it consistently sounds like you.",
      },
      {
        question: "Can it collaborate with other AI employees?",
        answer:
          "Yes — that is the point of the office. The AI marketer can hand tasks to the AI content writer, request assets, and sync with the AI SDR on campaign timing, and you can watch those handoffs happen in the 3D workspace.",
      },
    ],
  },
  {
    slug: "ai-developer",
    shortName: "AI Developer",
    title: "AI Developer Agent — Hire an AI Software Engineer | mokaid",
    metaDescription:
      "Hire an AI developer that fixes bugs, ships small features, and opens pull requests — working visibly in mokaid's 3D office with code review gates.",
    h1: "An AI developer that ships, with a paper trail",
    intro:
      "An AI developer in mokaid is not a code-completion plugin — it is a teammate with a backlog. Assign it bug fixes, small features, refactors, or test coverage, and it works the queue from its desk in your virtual office. Every change lands as a reviewable pull request; nothing merges without the gates you define.",
    definition:
      "An AI developer agent is an autonomous AI employee that takes engineering tasks from backlog to pull request — writing code, running tests, and documenting changes — under code-review guardrails.",
    responsibilities: [
      "Pick up scoped tickets: bug fixes, small features, refactors",
      "Open pull requests with tests and clear descriptions",
      "Investigate issues and write reproduction notes",
      "Keep documentation in sync with code changes",
      "Answer questions about the codebase from teammates",
    ],
    integrations: ["GitHub", "Linear", "Slack", "Notion"],
    outcomes: [
      "Backlog shrinks while your senior engineers stay on hard problems",
      "Every change reviewable — the AI never pushes to main directly",
      "Institutional knowledge captured in docs, not lost in chat",
    ],
    faq: [
      {
        question: "Does the AI developer have direct access to production?",
        answer:
          "No. It works through pull requests and the permissions you grant. Approval gates and audit logs cover every action, so the AI developer operates with less standing access than most contractors.",
      },
      {
        question: "What tasks is it best at?",
        answer:
          "Well-scoped tickets: bug fixes with clear reproduction steps, small features, test coverage, refactors, and documentation. You stay in charge of architecture; it handles the volume.",
      },
    ],
  },
  {
    slug: "ai-support-agent",
    shortName: "AI Support Agent",
    title: "AI Customer Support Employee — 24/7 Support | mokaid",
    metaDescription:
      "Hire an AI support employee that answers customers 24/7, escalates edge cases to humans, and is visible at work in mokaid's 3D virtual office.",
    h1: "Customer support that never sleeps — and never hides",
    intro:
      "Support is the clearest win for an AI employee: high volume, well-defined, around the clock. mokaid's AI support agent answers from your actual documentation, escalates what it should not answer, and logs every conversation. On the office floor, you can see it at its desk handling tickets — and see the queue it is working through.",
    definition:
      "An AI support employee is an autonomous AI worker that resolves customer questions 24/7 from your knowledge base, with automatic escalation of sensitive or novel cases to humans.",
    responsibilities: [
      "Answer customer questions grounded in your docs and policies",
      "Triage and tag incoming tickets by urgency and topic",
      "Escalate refunds, edge cases, and angry customers to humans",
      "Turn recurring questions into knowledge-base drafts",
      "Summarize support trends weekly",
    ],
    integrations: ["Gmail", "Slack", "Notion", "Helpdesk via MCP"],
    outcomes: [
      "First response in seconds, at 3 a.m. included",
      "Humans only see the tickets that genuinely need them",
      "Support insights flow back into product and docs",
    ],
    faq: [
      {
        question: "What stops it from making things up to customers?",
        answer:
          "Answers are grounded in the knowledge you train it on, and you define escalation rules for anything outside that scope. You can also gate entire categories — refunds, legal, security — so they always route to a human.",
      },
      {
        question: "Can it handle multiple languages?",
        answer:
          "Yes, it can converse in the languages your customers use while keeping your policies and tone consistent.",
      },
    ],
  },
  {
    slug: "ai-executive-assistant",
    shortName: "AI Executive Assistant",
    title: "AI Executive Assistant — Inbox, Calendar, Follow-ups | mokaid",
    metaDescription:
      "Hire an AI executive assistant for inbox triage, scheduling, meeting prep, and follow-ups — a visible teammate in mokaid's 3D virtual office.",
    h1: "An executive assistant for everyone on the team",
    intro:
      "The mokaid AI executive assistant does the coordination work that eats your day: inbox triage, scheduling, meeting prep, follow-up chasing. Unlike a personal AI assistant trapped in one person's chat window, it is a visible member of the office who can coordinate across your whole team — human and AI.",
    definition:
      "An AI executive assistant is an autonomous AI employee that owns scheduling, inbox triage, meeting preparation, and follow-up tracking for a person or a team.",
    responsibilities: [
      "Triage inboxes: draft replies, flag what matters, archive noise",
      "Schedule meetings and resolve calendar conflicts",
      "Prepare briefs before meetings and capture action items after",
      "Chase outstanding follow-ups so nothing slips",
      "Coordinate handoffs between team members and other AI employees",
    ],
    integrations: ["Gmail", "Google Calendar", "Slack", "Notion"],
    outcomes: [
      "Hours of coordination work removed per person per week",
      "Meetings arrive with context; action items actually get tracked",
      "One assistant serving the whole team, not one seat",
    ],
    faq: [
      {
        question: "Can it send emails as me?",
        answer:
          "It drafts replies for your approval by default. You choose per category what it may send autonomously — many teams start with scheduling emails only and expand from there.",
      },
      {
        question: "How does it know my preferences?",
        answer:
          "It learns from your instructions and the corrections you make, and stores durable preferences in its memory — meeting hours, VIP senders, tone — so quality compounds over time.",
      },
    ],
  },
  {
    slug: "ai-data-analyst",
    shortName: "AI Data Analyst",
    title: "AI Data Analyst — Reports & Insights on Demand | mokaid",
    metaDescription:
      "Hire an AI data analyst that turns raw data into weekly reports and answers ad-hoc questions — working transparently in mokaid's 3D virtual office.",
    h1: "A data analyst who never sits on a request",
    intro:
      "Every team has questions that die in a dashboard backlog. mokaid's AI data analyst takes them as tasks: it pulls the data, does the analysis, and returns a readable answer with its working shown. Recurring reports become its weekly routine — you see it at its desk preparing them.",
    definition:
      "An AI data analyst is an autonomous AI employee that answers business questions from your data — building recurring reports, ad-hoc analyses, and plain-language summaries with sources shown.",
    responsibilities: [
      "Produce recurring weekly and monthly performance reports",
      "Answer ad-hoc data questions with methodology shown",
      "Monitor key metrics and flag anomalies proactively",
      "Maintain a glossary of metric definitions for the team",
      "Prepare data summaries for board and investor updates",
    ],
    integrations: ["Google Drive", "Notion", "Slack", "Databases via MCP"],
    outcomes: [
      "Questions answered in minutes, not sprint cycles",
      "Consistent metric definitions across the company",
      "Anomalies surfaced before they become surprises",
    ],
    faq: [
      {
        question: "How do I know its analysis is right?",
        answer:
          "It shows its work: sources, queries, and assumptions come with every answer. Approval gates let a human review analyses before they are shared widely.",
      },
    ],
  },
  {
    slug: "ai-content-writer",
    shortName: "AI Content Writer",
    title: "AI Content Writer — Blogs, Docs & Newsletters | mokaid",
    metaDescription:
      "Hire an AI content writer that drafts blog posts, docs, and newsletters in your voice — visible at its desk in mokaid's 3D virtual office.",
    h1: "A content writer with a queue, a voice, and a desk",
    intro:
      "Content programs fail on consistency, not ideas. mokaid's AI content writer treats content as a job: it works a queue of briefs, drafts in your trained voice, revises on feedback, and ships on schedule. You can literally watch the work happen in the office view.",
    definition:
      "An AI content writer is an autonomous AI employee that drafts, revises, and maintains written content — blog posts, documentation, newsletters — in a trained brand voice on a reliable cadence.",
    responsibilities: [
      "Draft blog posts and articles from briefs or from scratch",
      "Keep product documentation current as features ship",
      "Write and schedule newsletters",
      "Revise drafts based on human feedback until approved",
      "Maintain a style guide and apply it consistently",
    ],
    integrations: ["Notion", "Google Drive", "Slack", "GitHub"],
    outcomes: [
      "A publishing cadence that survives busy weeks",
      "Docs that stay in sync with the product",
      "Every piece human-approved before it goes live",
    ],
    faq: [
      {
        question: "Will the content read like AI slop?",
        answer:
          "Not if you train and gate it. The writer learns from your best existing content, follows your style guide, and nothing publishes without passing your approval gate. You are the editor-in-chief; it is the staff writer.",
      },
    ],
  },
  {
    slug: "ai-recruiter",
    shortName: "AI Recruiter",
    title: "AI Recruiter — Sourcing, Screening & Scheduling | mokaid",
    metaDescription:
      "Hire an AI recruiter that sources candidates, screens applications, and schedules interviews — a transparent teammate in mokaid's 3D virtual office.",
    h1: "A recruiter that keeps every candidate warm",
    intro:
      "Recruiting stalls on logistics: sourcing lists, screening passes, scheduling loops, follow-up emails. mokaid's AI recruiter owns that machinery. Humans make every hiring decision; the AI makes sure no candidate waits three days for a reply.",
    definition:
      "An AI recruiter is an autonomous AI employee that handles recruiting operations — sourcing, application screening against defined criteria, interview scheduling, and candidate communication — while humans make all hiring decisions.",
    responsibilities: [
      "Build sourcing lists matched to the role profile",
      "Screen applications against criteria you define",
      "Schedule interview loops and handle rescheduling",
      "Keep candidates informed at every stage",
      "Maintain the pipeline in your ATS with full audit trail",
    ],
    integrations: ["Gmail", "Google Calendar", "Slack", "Notion", "ATS via MCP"],
    outcomes: [
      "Time-to-first-response measured in minutes",
      "Structured, criteria-based screening with human review",
      "A candidate experience that reflects well on your brand",
    ],
    faq: [
      {
        question: "Does the AI decide who gets hired?",
        answer:
          "No. It handles operations — sourcing, screening against your written criteria, scheduling, communication — and flags its reasoning for review. Interview evaluations and offers stay entirely human.",
      },
    ],
  },
];

export function getRole(slug: string): Role | undefined {
  return roles.find((r) => r.slug === slug);
}
