import { useState } from "react";
import { Check, Coins, Crown, Star, Users, Zap } from "lucide-react";
import { Link } from "@tanstack/react-router";
import {
  Breadcrumbs,
  CtaBanner,
  FaqSection,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { cn } from "@/lib/cn";
import { breadcrumbJsonLd, canonicalUrl, faqJsonLd, SITE } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

// Static mirror of the plan catalog (apps/api Mokaid.Billing @plan_seeds).
// This page is prerendered for SEO, so it cannot fetch the authenticated
// billing API — keep it in sync when the catalog changes.
const plans = [
  {
    key: "free",
    name: "Free",
    icon: Zap,
    tagline: "Try your first AI employee",
    monthly: 0,
    yearly: 0,
    yearlyPerMonth: 0,
    credits: "300 credits / month",
    agents: "1 AI employee",
    features: ["3D office", "Chat & tasks", "Community support"],
    cta: "Start free",
    featured: false,
  },
  {
    key: "starter",
    name: "Starter",
    icon: Star,
    tagline: "For solo builders",
    monthly: 49,
    yearly: 490,
    yearlyPerMonth: 41,
    credits: "5,000 credits / month",
    agents: "3 AI employees",
    features: [
      "Live Preview & versions",
      "Unlimited MCP integrations",
      "Project Knowledge Graph",
      "Auto-recharge available",
    ],
    cta: "Choose Starter",
    featured: false,
  },
  {
    key: "team",
    name: "Team",
    icon: Users,
    tagline: "For growing teams",
    monthly: 89,
    yearly: 890,
    yearlyPerMonth: 74,
    credits: "10,000 credits / month",
    agents: "6 AI employees",
    features: [
      "Live Preview & versions",
      "Unlimited MCP integrations",
      "Workspace Knowledge Graph",
      "Team collaboration",
      "Auto-recharge available",
    ],
    cta: "Choose Team",
    featured: true,
  },
  {
    key: "professional",
    name: "Professional",
    icon: Crown,
    tagline: "Fill the 9-desk office",
    monthly: 149,
    yearly: 1490,
    yearlyPerMonth: 124,
    credits: "20,000 credits / month",
    agents: "9 AI employees",
    features: [
      "Live Preview & versions",
      "Unlimited MCP integrations",
      "Workspace Knowledge Graph",
      "Priority support",
      "Auto-recharge available",
    ],
    cta: "Choose Professional",
    featured: false,
  },
] as const;

const faqs = [
  {
    question: "What are AI credits?",
    answer:
      "Credits meter your AI employees' work: running tasks, chatting, ingesting knowledge, building websites. Every plan includes a monthly grant that refreshes each month — on yearly billing too — and you can top up anytime with one-time credit packs that never expire.",
  },
  {
    question: "What happens when I run out of credits?",
    answer:
      "Your agents pause new work until credits refresh or you top up. Turn on auto-recharge and we automatically buy your preferred pack when the balance drops below your threshold, so work never stops.",
  },
  {
    question: "Can I change plans later?",
    answer:
      "Yes. Upgrades apply immediately with a fresh credit grant. Downgrades keep your existing agents but block new hires over the lower plan's limit.",
  },
  {
    question: "Do you offer yearly billing?",
    answer:
      "Yes — yearly billing saves about 17% (2 months free). We show rounded monthly equivalents ($41, $74, $124) so prices stay easy to read; you are billed the exact yearly total.",
  },
  {
    question: "Is there a free trial?",
    answer:
      "The Free plan is free forever, with a real AI employee and monthly credits — no credit card required. Upgrade only when you need more employees or credits.",
  },
];

const breadcrumbs = [
  { name: "Home", path: "/" },
  { name: "Pricing", path: "/pricing" },
];

export function PricingPage() {
  const [cycle, setCycle] = useState<"monthly" | "yearly">("monthly");
  useSeo({
    title: "Pricing — Hire AI Employees From Free | mokaid",
    description:
      "Simple pricing for your AI workforce: start free with one AI employee, scale to a 9-desk office. Monthly credits included on every plan, top-ups never expire.",
    path: "/pricing",
    jsonLd: [
      breadcrumbJsonLd(breadcrumbs),
      faqJsonLd(faqs),
      {
        "@context": "https://schema.org",
        "@type": "Product",
        "@id": `${SITE.url}/pricing#product`,
        name: "mokaid — AI employees",
        description:
          "Autonomous AI employees working in a live 3D office: tasks, chat, knowledge, websites.",
        url: canonicalUrl("/pricing"),
        offers: plans.map((plan) => ({
          "@type": "Offer",
          name: `${plan.name} plan`,
          price: plan.monthly,
          priceCurrency: "USD",
          url: canonicalUrl("/pricing"),
        })),
      },
    ],
  });

  return (
    <MarketingLayout>
      <Breadcrumbs items={breadcrumbs} />

      <section className="mx-auto max-w-4xl px-4 pb-4 pt-12 text-center sm:px-6">
        <h1 className="mk-seo-display text-4xl font-bold leading-tight sm:text-5xl">
          Pricing that scales with your AI workforce
        </h1>
        <p className="mx-auto mt-5 max-w-2xl text-lg leading-relaxed text-text-secondary">
          Start free with one AI employee. Every plan includes monthly AI credits — top-ups never
          expire, and yearly billing saves 17%.
        </p>
        <p className="mx-auto mt-3 max-w-2xl text-sm leading-relaxed text-text-muted">
          Work in Mokaid Desktop. Manage your plan, usage and payments here on the web.
        </p>
        <div
          className="mt-8 inline-flex flex-wrap items-center justify-center gap-1 rounded-xl bg-surface p-1"
          role="group"
          aria-label="Billing cycle"
        >
          {(["monthly", "yearly"] as const).map((option) => (
            <button
              type="button"
              key={option}
              aria-pressed={cycle === option}
              onClick={() => setCycle(option)}
              className={cn(
                "mk-focus-ring min-h-11 rounded-lg px-5 text-sm font-medium transition-colors",
                cycle === option ? "bg-primary text-white" : "text-text-secondary hover:text-text",
              )}
            >
              {option === "monthly" ? "Monthly" : "Yearly · save 17%"}
            </button>
          ))}
        </div>
      </section>

      <section className="mx-auto max-w-7xl px-4 py-10 sm:px-6">
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          {plans.map((plan) => {
            const Icon = plan.icon;
            return (
              <div
                key={plan.key}
                className={cn(
                  "mk-card relative flex flex-col border p-6",
                  plan.featured
                    ? "border-primary shadow-lg shadow-primary/10 ring-1 ring-primary/20"
                    : "border-border",
                )}
              >
                {plan.featured && (
                  <div className="absolute -top-3 left-1/2 -translate-x-1/2 whitespace-nowrap">
                    <span className="inline-block rounded-full bg-primary px-3 py-1 text-[10px] font-bold uppercase tracking-wider text-white">
                      Most Popular
                    </span>
                  </div>
                )}

                <div className="mb-4 flex items-center gap-2.5">
                  <span
                    className={cn(
                      "flex h-9 w-9 items-center justify-center rounded-lg",
                      plan.featured
                        ? "bg-primary/15 text-primary"
                        : "bg-surface/60 text-text-muted",
                    )}
                  >
                    <Icon size={17} />
                  </span>
                  <div>
                    <p className="text-base font-bold text-text">{plan.name}</p>
                    <p className="text-[11px] text-text-muted">{plan.tagline}</p>
                  </div>
                </div>

                <div className="mb-5">
                  {plan.monthly === 0 ? (
                    <>
                      <p className="text-3xl font-bold text-text">Free</p>
                      <p className="mt-0.5 text-xs text-text-muted">No credit card required</p>
                    </>
                  ) : (
                    <>
                      <p className="text-3xl font-bold text-text">
                        ${cycle === "yearly" ? plan.yearlyPerMonth : plan.monthly}
                        <span className="text-sm font-normal text-text-muted"> / month</span>
                      </p>
                      <p className="mt-0.5 text-xs text-text-muted">
                        {cycle === "yearly" ? `$${plan.yearly} billed yearly` : "Billed monthly"}
                      </p>
                    </>
                  )}
                </div>

                <div className="mb-5 space-y-2 rounded-xl bg-surface/50 px-4 py-3">
                  <p className="flex items-center gap-2 text-sm font-semibold text-text">
                    <Coins size={14} className="shrink-0 text-primary-light" />
                    {plan.credits}
                  </p>
                  <p className="flex items-center gap-2 text-sm text-text-secondary">
                    <Crown size={14} className="shrink-0 text-primary-light" />
                    {plan.agents}
                  </p>
                </div>

                <ul className="mb-6 flex-1 space-y-2.5">
                  {plan.features.map((feature) => (
                    <li
                      key={feature}
                      className="flex items-start gap-2 text-[13px] text-text-secondary"
                    >
                      <Check
                        size={14}
                        className={cn(
                          "mt-0.5 shrink-0",
                          plan.featured ? "text-primary" : "text-success",
                        )}
                      />
                      <span>{feature}</span>
                    </li>
                  ))}
                </ul>

                <Link
                  to={plan.key === "free" ? "/signup" : "/account/plans"}
                  className={cn(
                    "mk-focus-ring inline-flex min-h-11 w-full items-center justify-center rounded-md px-4 py-3 text-center text-sm font-semibold transition-colors",
                    plan.featured
                      ? "bg-primary text-white hover:bg-primary-dark"
                      : "bg-primary/10 text-text hover:bg-primary/20",
                  )}
                >
                  {plan.cta}
                </Link>
              </div>
            );
          })}
        </div>

        <p className="mt-6 text-center text-sm text-text-muted">
          Prices in USD. Review your plan and billing cycle in your account before checkout.
        </p>
        <p className="mt-3 text-center text-sm text-text-muted">
          Need more than 9 AI employees or custom terms?{" "}
          <a
            href="mailto:hello@mokaid.com"
            className="text-primary-light underline underline-offset-2 hover:text-text"
          >
            Talk to us about Enterprise
          </a>
          .
        </p>
      </section>

      <FaqSection items={faqs} heading="Pricing questions, answered" />
      <CtaBanner />
    </MarketingLayout>
  );
}
