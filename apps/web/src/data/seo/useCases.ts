import type { FaqItem } from "@/lib/seo";

export interface UseCase {
  slug: string;
  shortName: string;
  title: string;
  metaDescription: string;
  h1: string;
  intro: string;
  painPoints: string[];
  solution: string;
  recommendedRoles: string[]; // role slugs
  faq: FaqItem[];
}

export const useCases: UseCase[] = [
  {
    slug: "startups",
    shortName: "Startups",
    title: "AI Employees for Startups — Ship More With a Tiny Team | mokaid",
    metaDescription:
      "Give your startup an AI workforce: AI SDRs, marketers, and support agents working visibly in a 3D office. Scale output before you scale headcount.",
    h1: "AI employees for startups: headcount you don't have to raise for",
    intro:
      "Early-stage teams lose to the calendar, not the competition. Every founder is doing three jobs badly. mokaid lets a five-person startup operate like a twenty-person company: AI employees own outbound, support, content, and coordination, while the humans stay on product and customers. And because the workforce is visible in a 3D office, you always know what your AI headcount is doing.",
    painPoints: [
      "Founders doing sales, support, and marketing between sprints",
      "No budget for the first ops, SDR, or support hire",
      "Investor updates and reporting always late",
      "Automation scripts nobody trusts or maintains",
    ],
    solution:
      "Start with one AI employee owning your most repetitive stream — usually support or outbound. Add roles as trust builds. Approval gates keep founders in control of everything customer-facing, and the office view replaces the anxiety of invisible automation with a workforce you can watch.",
    recommendedRoles: ["ai-sdr", "ai-support-agent", "ai-executive-assistant"],
    faq: [
      {
        question: "Is this affordable for a pre-seed company?",
        answer:
          "An AI employee costs a fraction of the salary of the equivalent hire and starts contributing the same day. You can start free and add roles as revenue grows.",
      },
      {
        question: "How much time does setup take?",
        answer:
          "Minutes to hire, a few hours to train on your docs and connect tools, and about a week of reviewing output through approval gates before you can loosen supervision.",
      },
    ],
  },
  {
    slug: "agencies",
    shortName: "Agencies",
    title: "AI Employees for Agencies — Scale Delivery, Not Payroll | mokaid",
    metaDescription:
      "Agencies use mokaid's AI employees to scale content, reporting, and client ops without new hires — every AI worker visible in a 3D office.",
    h1: "AI employees for agencies: margin back on every account",
    intro:
      "Agency economics break when every new client means new headcount. mokaid gives agencies leverage: AI content writers, analysts, and assistants absorb the repeatable delivery work — drafts, reports, status updates — while your strategists stay on the thinking clients actually pay for.",
    painPoints: [
      "Client reporting eating billable hours every month",
      "Content production bottlenecked on a few writers",
      "Junior work quality inconsistent across accounts",
      "Scope creep absorbed by unpaid overtime",
    ],
    solution:
      "Assign each account team an AI content writer and an AI data analyst. Reports, first drafts, and status updates become AI-owned tasks with human review. The 3D office gives account leads a live view of what is in progress across every client, without a single status meeting.",
    recommendedRoles: ["ai-content-writer", "ai-data-analyst", "ai-executive-assistant"],
    faq: [
      {
        question: "Can we white-label the output?",
        answer:
          "Yes. The work product is yours: drafts, reports, and deliverables come out in your templates and brand voice, reviewed by your team before anything reaches a client.",
      },
      {
        question: "How do we keep client data separated?",
        answer:
          "Workspaces and per-employee permissions keep client contexts isolated, and audit logs record every access — stronger separation than most shared-drive setups.",
      },
    ],
  },
  {
    slug: "ecommerce",
    shortName: "E-commerce",
    title: "AI Employees for E-commerce — Support & Content 24/7 | mokaid",
    metaDescription:
      "E-commerce teams run 24/7 customer support, product content, and reporting with mokaid AI employees — visible, governed, and always on.",
    h1: "AI employees for e-commerce: your store never closes, now your team doesn't either",
    intro:
      "E-commerce runs around the clock; your team cannot. mokaid's AI employees cover the hours and the volume: support that answers at 2 a.m., product descriptions that keep pace with your catalog, and performance summaries waiting in Slack before your coffee.",
    painPoints: [
      "Support tickets piling up overnight and on weekends",
      "Hundreds of product descriptions to write and update",
      "Promotions and email campaigns limited by content bandwidth",
      "Sales data reviewed weekly instead of daily",
    ],
    solution:
      "An AI support agent handles pre-sale and post-sale questions grounded in your policies, escalating refunds and edge cases. An AI content writer keeps product pages and campaign emails flowing. An AI data analyst reports daily on sales, returns, and ad performance.",
    recommendedRoles: ["ai-support-agent", "ai-content-writer", "ai-data-analyst"],
    faq: [
      {
        question: "Can the AI issue refunds?",
        answer:
          "Only under rules you define. Most stores route all refunds through an approval gate: the AI prepares the case, a human clicks approve. High-trust teams automate small amounts and gate the rest.",
      },
    ],
  },
  {
    slug: "saas",
    shortName: "SaaS Teams",
    title: "AI Employees for SaaS — Support, Docs & Pipeline | mokaid",
    metaDescription:
      "SaaS teams use mokaid AI employees for technical support, always-current docs, outbound pipeline, and engineering backlog — all visible in a 3D office.",
    h1: "AI employees for SaaS teams: compounding leverage on every function",
    intro:
      "SaaS companies are made of exactly the work AI employees are best at: technical support with documented answers, docs that must track the product, outbound that must be personalized at volume, and a backlog of well-scoped engineering tickets. mokaid puts a role-based AI employee on each stream and gives you one office to supervise them all.",
    painPoints: [
      "Support burying engineers in interrupt-driven questions",
      "Documentation perpetually behind the product",
      "Outbound pipeline inconsistent between launches",
      "Small bugs and papercuts never reaching the sprint",
    ],
    solution:
      "Deploy an AI support agent grounded in your docs, an AI content writer that updates those docs as features ship, an AI SDR for steady outbound, and an AI developer for the papercut backlog. They share the same knowledge base and coordinate in the same visible office.",
    recommendedRoles: ["ai-support-agent", "ai-developer", "ai-sdr", "ai-content-writer"],
    faq: [
      {
        question: "How do AI employees stay accurate about our product?",
        answer:
          "They answer from your maintained knowledge base, and the AI content writer keeps that knowledge current as the product changes — a loop that gets more accurate over time, not less.",
      },
    ],
  },
  {
    slug: "solo-founders",
    shortName: "Solo Founders",
    title: "AI Employees for Solo Founders — Your First Team | mokaid",
    metaDescription:
      "Solo founders build their first team with mokaid AI employees: support, marketing, and admin handled by visible AI teammates in a 3D office.",
    h1: "Solo founder, full team: AI employees as your first hires",
    intro:
      "The hardest stage of any company is one person doing everything. mokaid gives solo founders what they actually need — not another tool to operate, but colleagues who take work off the plate. Walk into your 3D office in the morning, see your AI support agent already answering, your AI marketer drafting the newsletter, and your assistant holding your calendar together.",
    painPoints: [
      "Context switching between builder, marketer, and support rep",
      "Customer questions answered at midnight or not at all",
      "Marketing happening only when everything else is done",
      "No one to delegate to, ever",
    ],
    solution:
      "Start with the AI executive assistant to reclaim your calendar and inbox, then add support and marketing roles. Approval gates mean nothing ships without your sign-off — you stay the CEO, editor, and final word, with a fraction of the load.",
    recommendedRoles: ["ai-executive-assistant", "ai-support-agent", "ai-marketer"],
    faq: [
      {
        question: "Isn't this just ChatGPT with extra steps?",
        answer:
          "No. A chat assistant answers when you prompt it and forgets you between sessions. mokaid AI employees hold roles: they work their queues continuously, remember your preferences, use your real tools, and report back — whether or not you are online.",
      },
    ],
  },
];

export function getUseCase(slug: string): UseCase | undefined {
  return useCases.find((u) => u.slug === slug);
}
