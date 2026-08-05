import { ArrowRight } from "lucide-react";
import {
  Breadcrumbs,
  CtaBanner,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { comparisons } from "@/data/seo/comparisons";
import { breadcrumbJsonLd } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

const breadcrumbs = [
  { name: "Home", path: "/" },
  { name: "Compare", path: "/compare" },
];

export function CompareIndexPage() {
  useSeo({
    title: "Compare mokaid — vs Lindy, Artisan, Relevance AI, MultiOn | mokaid",
    description:
      "Honest comparisons of mokaid against other AI employee and AI agent platforms. See where each tool wins and which fits your team.",
    path: "/compare",
    jsonLd: [breadcrumbJsonLd(breadcrumbs)],
  });

  return (
    <MarketingLayout>
      <Breadcrumbs items={breadcrumbs} />

      <section className="mx-auto max-w-4xl px-4 pb-8 pt-12 text-center sm:px-6">
        <h1 className="mk-seo-display text-4xl font-bold leading-tight sm:text-5xl">
          How mokaid compares
        </h1>
        <p className="mx-auto mt-5 max-w-2xl text-lg leading-relaxed text-text-secondary">
          The AI workforce space is crowded with agents, assistants, and automation tools.
          These honest comparisons show where each platform wins — including where mokaid
          isn't the right fit.
        </p>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-10 sm:px-6">
        <div className="grid gap-4 sm:grid-cols-2">
          {comparisons.map((comparison) => (
            <a
              key={comparison.slug}
              href={`/compare/${comparison.slug}`}
              className="mk-card mk-card-interactive group border border-border px-6 py-6 transition-colors hover:border-primary/30"
            >
              <h2 className="mk-seo-display text-xl font-semibold text-text group-hover:text-primary-light">
                mokaid vs {comparison.competitor}
              </h2>
              <p className="mt-2 line-clamp-3 text-sm leading-relaxed text-text-secondary">
                {comparison.intro}
              </p>
              <span className="mt-4 inline-flex items-center gap-1 text-sm font-medium text-primary-light">
                Read the comparison <ArrowRight size={14} />
              </span>
            </a>
          ))}
        </div>
      </section>

      <CtaBanner />
    </MarketingLayout>
  );
}
