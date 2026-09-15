import { type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowRight, ChevronDown } from "lucide-react";
import { SiteFooter } from "@/components/landing/site-footer";
import { SiteHeader } from "@/components/marketing/site-header";
import type { BreadcrumbItem, FaqItem } from "@/lib/seo";
import { DESKTOP_ONLY_WEB } from "@/lib/desktop-rollout";

/** Shared public shell; the router manages scroll positions and hash navigation. */
export function MarketingLayout({ children }: { children: ReactNode }) {
  return (
    <div className="mk-landing min-h-screen bg-bg-deep text-text">
      <SiteHeader />
      <main id="main-content" tabIndex={-1}>
        {children}
      </main>
      <SiteFooter />
    </div>
  );
}

export function Breadcrumbs({ items }: { items: BreadcrumbItem[] }) {
  return (
    <nav aria-label="Breadcrumb" className="mx-auto max-w-6xl px-4 pt-6 sm:px-6">
      <ol className="flex flex-wrap items-center gap-1.5 text-xs text-text-muted">
        {items.map((item, i) => (
          <li key={item.path} className="flex items-center gap-1.5">
            {i > 0 && <span aria-hidden="true">/</span>}
            {i === items.length - 1 ? (
              <span aria-current="page" className="text-text-secondary">
                {item.name}
              </span>
            ) : (
              <Link
                to={item.path}
                className="mk-focus-ring rounded-sm transition-colors hover:text-text"
              >
                {item.name}
              </Link>
            )}
          </li>
        ))}
      </ol>
    </nav>
  );
}

export function FaqSection({
  items,
  heading = "Frequently asked questions",
}: {
  items: FaqItem[];
  heading?: string;
}) {
  return (
    <section className="mx-auto max-w-3xl px-4 py-12 sm:px-6" aria-labelledby="faq-heading">
      <h2 id="faq-heading" className="mk-seo-display mb-6 text-2xl font-bold">
        {heading}
      </h2>
      <div className="space-y-3">
        {items.map((item) => (
          <details key={item.question} className="mk-card group border border-border px-5 py-4">
            <summary className="mk-focus-ring flex cursor-pointer list-none items-start justify-between gap-4 rounded-sm text-base font-semibold text-text [&::-webkit-details-marker]:hidden">
              {item.question}
              <ChevronDown
                size={18}
                aria-hidden
                className="mt-1 shrink-0 text-primary-light transition-transform group-open:rotate-180 motion-reduce:transition-none"
              />
            </summary>
            <p className="mt-3 text-sm leading-relaxed text-text-secondary">{item.answer}</p>
          </details>
        ))}
      </div>
    </section>
  );
}

export function CtaBanner({
  heading = "Hire your first AI employee today",
  body = "Bring your AI team together in the Mokaid desktop app. Assign work, follow progress and manage your account on the web.",
}: {
  heading?: string;
  body?: string;
}) {
  return (
    <section className="mx-auto max-w-6xl px-4 py-16 sm:px-6">
      <div
        className="mk-card relative overflow-hidden border border-primary/15 px-6 py-12 text-center sm:px-12"
        style={{
          background: "linear-gradient(135deg, rgba(124,92,255,0.14) 0%, rgba(18,18,26,1) 60%)",
        }}
      >
        <h2 className="mk-seo-display text-2xl font-bold sm:text-3xl">{heading}</h2>
        <p className="mx-auto mt-3 max-w-xl text-text-secondary">{body}</p>
        <div className="mt-7 flex flex-wrap items-center justify-center gap-3">
          <Link
            to={DESKTOP_ONLY_WEB ? "/download" : "/signup"}
            className="mk-focus-ring inline-flex min-h-11 items-center justify-center gap-2 rounded-lg bg-primary px-6 text-sm font-semibold text-white transition-colors hover:bg-primary-dark"
          >
            {DESKTOP_ONLY_WEB ? "Download Mokaid" : "Get started free"}{" "}
            <ArrowRight size={15} aria-hidden />
          </Link>
          <Link
            to="/"
            hash="product"
            className="mk-focus-ring inline-flex min-h-11 items-center justify-center rounded-lg px-6 text-sm font-medium text-text-secondary transition-colors hover:bg-primary/10 hover:text-text"
          >
            See the product
          </Link>
        </div>
      </div>
    </section>
  );
}
