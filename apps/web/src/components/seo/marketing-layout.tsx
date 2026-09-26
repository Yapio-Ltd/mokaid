import { useEffect, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowRight } from "lucide-react";
import { SiteFooter } from "@/components/landing/site-footer";
import { SiteHeader } from "@/components/landing/site-header";
import { Button } from "@/components/ui/button";
import type { BreadcrumbItem, FaqItem } from "@/lib/seo";
import { DESKTOP_ONLY_WEB } from "@/lib/desktop-rollout";

/** Shared public shell for the SEO and editorial pages. */
export function MarketingLayout({ children }: { children: ReactNode }) {
  useEffect(() => {
    // These pages use document scroll like the landing (app shell uses inner scroll).
    document.documentElement.style.overflowY = "auto";
    window.scrollTo(0, 0);
    return () => {
      document.documentElement.style.overflowY = "";
    };
  }, []);

  return (
    <div className="mk-landing min-h-full overflow-x-clip bg-bg-deep text-text">
      <SiteHeader />

      <main>{children}</main>

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
              <a href={item.path} className="transition-colors hover:text-text">
                {item.name}
              </a>
            )}
          </li>
        ))}
      </ol>
    </nav>
  );
}

export function FaqSection({ items, heading = "Frequently asked questions" }: { items: FaqItem[]; heading?: string }) {
  return (
    <section className="mx-auto max-w-3xl px-4 py-12 sm:px-6" aria-labelledby="faq-heading">
      <h2 id="faq-heading" className="mk-seo-display mb-6 text-2xl font-bold">
        {heading}
      </h2>
      <div className="space-y-3">
        {items.map((item) => (
          <details key={item.question} className="mk-card border border-border px-5 py-4">
            <summary className="cursor-pointer list-none text-base font-semibold text-text">
              {item.question}
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
  body = "Spin up an autonomous AI teammate in minutes, give it real work, and watch it get done — live, in your 3D office.",
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
          <Link to={DESKTOP_ONLY_WEB ? "/download" : "/signup"}>
            <Button className="min-h-11 px-6 shadow-glow">
              {DESKTOP_ONLY_WEB ? "Download Mokaid" : "Get started free"} <ArrowRight size={15} />
            </Button>
          </Link>
          <Link to="/">
            <Button variant="ghost" className="min-h-11 px-6 text-text-secondary hover:text-text">
              See the product
            </Button>
          </Link>
        </div>
      </div>
    </section>
  );
}
