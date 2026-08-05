import { Link } from "@tanstack/react-router";
import { ArrowRight } from "lucide-react";
import {
  Breadcrumbs,
  CtaBanner,
  FaqSection,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { Button } from "@/components/ui/button";
import { roles } from "@/data/seo/roles";
import { breadcrumbJsonLd, faqJsonLd, SOFTWARE_JSONLD, type FaqItem } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

const pageFaq: FaqItem[] = [
  {
    question: "What exactly is an AI employee?",
    answer:
      "An AI employee is an autonomous AI worker with a persistent role, defined responsibilities, access to your tools, and accountability for outcomes. Unlike a chatbot, it keeps working between prompts: it holds a task queue, remembers context, escalates decisions for approval, and reports on its work.",
  },
  {
    question: "How is an AI employee different from an AI agent?",
    answer:
      "An AI agent executes bounded tasks. An AI employee is an agent given a durable role: identity, organizational memory, outcome ownership, and management controls like approval gates and audit trails. Agents run; employees hold jobs.",
  },
  {
    question: "Why does it matter that I can see my AI employees working?",
    answer:
      "Invisible automation is hard to trust and harder to manage. mokaid renders every AI employee in a real-time 3D office — at a desk, in a meeting, or moving between tasks — so supervising your AI workforce feels as natural as walking the floor of a real office.",
  },
  {
    question: "Do AI employees act without approval?",
    answer:
      "Only where you allow it. Every consequential action can pass through an approval gate. Most teams start with review-everything and gradually loosen supervision per role as trust builds.",
  },
  {
    question: "How fast can I hire my first AI employee?",
    answer:
      "Minutes. Pick a role, name your new teammate, connect the tools it needs, and give it its first task. It appears in your 3D office and starts working immediately.",
  },
];

const breadcrumbs = [
  { name: "Home", path: "/" },
  { name: "AI Employees", path: "/ai-employees" },
];

export function AiEmployeesIndexPage() {
  useSeo({
    title: "Hire AI Employees — Autonomous AI Workers in a 3D Office | mokaid",
    description:
      "Hire autonomous AI employees — SDRs, marketers, developers, support agents — and watch them work in a real-time 3D virtual office. Approval gates, audit trails, real output.",
    path: "/ai-employees",
    jsonLd: [SOFTWARE_JSONLD, breadcrumbJsonLd(breadcrumbs), faqJsonLd(pageFaq)],
  });

  return (
    <MarketingLayout>
      <Breadcrumbs items={breadcrumbs} />

      <section className="mx-auto max-w-4xl px-4 pb-10 pt-12 text-center sm:px-6 sm:pt-16">
        <p className="text-xs font-semibold uppercase tracking-[0.2em] text-primary-light">
          The AI Workforce OS
        </p>
        <h1 className="mk-seo-display mt-4 text-4xl font-bold leading-tight sm:text-5xl">
          Hire AI employees you can actually see working
        </h1>
        <p className="mx-auto mt-5 max-w-2xl text-lg leading-relaxed text-text-secondary">
          mokaid gives every AI worker a role, a task queue, and a desk in a real-time 3D
          virtual office. No black-box automation — a workforce you watch, manage, and
          trust.
        </p>
        <div className="mt-8 flex flex-wrap items-center justify-center gap-3">
          <Link to="/signup">
            <Button className="min-h-11 px-6 shadow-glow">
              Hire your first AI employee <ArrowRight size={15} />
            </Button>
          </Link>
        </div>
      </section>

      <section className="mx-auto max-w-3xl px-4 py-8 sm:px-6">
        <div className="mk-card border border-primary/15 px-6 py-6">
          <h2 className="mk-seo-display text-lg font-semibold text-text">
            What is an AI employee?
          </h2>
          <p className="mt-3 leading-relaxed text-text-secondary">
            An AI employee is an autonomous, role-based AI worker with a persistent
            identity, defined responsibilities, access to real business tools, and
            accountability for outcomes — managed like a team member rather than operated
            like software.
          </p>
          <p className="mt-3 text-sm text-text-muted">
            Related reading:{" "}
            <a href="/blog/what-is-an-ai-employee" className="text-primary-light underline underline-offset-2 hover:text-text">
              What is an AI employee?
            </a>{" "}
            ·{" "}
            <a href="/blog/ai-employee-vs-ai-agent" className="text-primary-light underline underline-offset-2 hover:text-text">
              AI employee vs AI agent
            </a>
          </p>
        </div>
      </section>

      <section className="mx-auto max-w-6xl px-4 py-12 sm:px-6" aria-labelledby="roles-heading">
        <h2 id="roles-heading" className="mk-seo-display text-2xl font-bold sm:text-3xl">
          Roles you can hire today
        </h2>
        <p className="mt-2 max-w-2xl text-text-secondary">
          Each role ships with a job description, recommended integrations, and sensible
          approval gates. Customize everything after hiring.
        </p>
        <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {roles.map((role) => (
            <a
              key={role.slug}
              href={`/ai-employees/${role.slug}`}
              className="mk-card mk-card-interactive group border border-border px-5 py-5 transition-colors hover:border-primary/30"
            >
              <h3 className="mk-seo-display text-lg font-semibold text-text group-hover:text-primary-light">
                {role.shortName}
              </h3>
              <p className="mt-2 line-clamp-3 text-sm leading-relaxed text-text-secondary">
                {role.definition}
              </p>
              <span className="mt-4 inline-flex items-center gap-1 text-sm font-medium text-primary-light">
                Learn more <ArrowRight size={14} />
              </span>
            </a>
          ))}
        </div>
      </section>

      <section className="mx-auto max-w-6xl px-4 py-12 sm:px-6" aria-labelledby="how-heading">
        <h2 id="how-heading" className="mk-seo-display text-2xl font-bold sm:text-3xl">
          How hiring works
        </h2>
        <div className="mt-8 grid gap-4 md:grid-cols-3">
          {[
            {
              step: "1",
              title: "Pick a role and hire",
              body: "Choose from ready-made roles or define your own. Your new AI employee gets a name, an avatar, and a desk in your 3D office.",
            },
            {
              step: "2",
              title: "Onboard like a real hire",
              body: "Connect tools (Gmail, Slack, Notion, GitHub and more via MCP), share your docs as its knowledge base, and set approval gates for anything consequential.",
            },
            {
              step: "3",
              title: "Assign work and watch",
              body: "Give it tasks or a standing charter. Watch progress live in the office, review outputs in the approval queue, and read its daily reports.",
            },
          ].map((item) => (
            <div key={item.step} className="mk-card border border-border px-5 py-6">
              <span className="mk-seo-display text-3xl font-bold text-primary-light">
                {item.step}
              </span>
              <h3 className="mt-3 text-base font-semibold text-text">{item.title}</h3>
              <p className="mt-2 text-sm leading-relaxed text-text-secondary">{item.body}</p>
            </div>
          ))}
        </div>
      </section>

      <FaqSection items={pageFaq} />
      <CtaBanner />
    </MarketingLayout>
  );
}
