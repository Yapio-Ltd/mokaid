import { Link, useParams } from "@tanstack/react-router";
import { ArrowRight } from "lucide-react";
import {
  Breadcrumbs,
  CtaBanner,
  FaqSection,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { Button } from "@/components/ui/button";
import { comparisons, getComparison } from "@/data/seo/comparisons";
import { breadcrumbJsonLd, faqJsonLd } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

function ComparisonNotFound() {
  useSeo({
    title: "Comparison not found | mokaid",
    description: "This comparison does not exist.",
    path: "/compare",
  });
  return (
    <MarketingLayout>
      <section className="mx-auto max-w-3xl px-4 py-24 text-center sm:px-6">
        <h1 className="mk-seo-display text-3xl font-bold">Comparison not found</h1>
        <p className="mt-3 text-text-secondary">Browse all available comparisons.</p>
        <a href="/compare" className="mt-6 inline-block">
          <Button className="min-h-11 px-6">
            Browse comparisons <ArrowRight size={15} />
          </Button>
        </a>
      </section>
    </MarketingLayout>
  );
}

export function CompareDetailPage() {
  const { slug } = useParams({ strict: false }) as { slug?: string };
  const comparison = slug ? getComparison(slug) : undefined;

  if (!comparison) return <ComparisonNotFound />;
  return <CompareContent slug={comparison.slug} />;
}

function CompareContent({ slug }: { slug: string }) {
  const comparison = getComparison(slug)!;
  const path = `/compare/${comparison.slug}`;
  const breadcrumbs = [
    { name: "Home", path: "/" },
    { name: "Compare", path: "/compare" },
    { name: `mokaid vs ${comparison.competitor}`, path },
  ];

  useSeo({
    title: comparison.title,
    description: comparison.metaDescription,
    path,
    jsonLd: [breadcrumbJsonLd(breadcrumbs), faqJsonLd(comparison.faq)],
  });

  const otherComparisons = comparisons.filter((c) => c.slug !== comparison.slug);

  return (
    <MarketingLayout>
      <Breadcrumbs items={breadcrumbs} />

      <section className="mx-auto max-w-4xl px-4 pb-8 pt-12 sm:px-6">
        <h1 className="mk-seo-display text-3xl font-bold leading-tight sm:text-4xl">
          {comparison.h1}
        </h1>
        <p className="mt-5 text-lg leading-relaxed text-text-secondary">{comparison.intro}</p>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-6 sm:px-6">
        <div className="mk-card border border-border px-6 py-5">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-text-muted">
            About {comparison.competitor}
          </h2>
          <p className="mt-2 leading-relaxed text-text-secondary">
            {comparison.competitorSummary}
          </p>
        </div>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="table-heading">
        <h2 id="table-heading" className="mk-seo-display text-2xl font-bold">
          Side by side
        </h2>
        <div className="mt-5 overflow-x-auto">
          <table className="w-full min-w-[560px] border-collapse text-sm">
            <thead>
              <tr>
                <th className="border border-border-strong bg-surface-raised px-4 py-3 text-left font-semibold text-text">
                  Dimension
                </th>
                <th className="border border-border-strong bg-primary/10 px-4 py-3 text-left font-semibold text-primary-light">
                  mokaid
                </th>
                <th className="border border-border-strong bg-surface-raised px-4 py-3 text-left font-semibold text-text">
                  {comparison.competitor}
                </th>
              </tr>
            </thead>
            <tbody>
              {comparison.rows.map((row) => (
                <tr key={row.dimension}>
                  <td className="border border-border-strong px-4 py-3 font-medium text-text">
                    {row.dimension}
                  </td>
                  <td className="border border-border-strong px-4 py-3 text-text-secondary">
                    {row.mokaid}
                  </td>
                  <td className="border border-border-strong px-4 py-3 text-text-secondary">
                    {row.competitor}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="verdict-heading">
        <h2 id="verdict-heading" className="mk-seo-display text-2xl font-bold">
          Which should you choose?
        </h2>
        <div className="mt-5 grid gap-4 sm:grid-cols-2">
          <div className="mk-card border border-border px-6 py-5">
            <h3 className="text-base font-semibold text-text">
              Choose {comparison.competitor} if…
            </h3>
            <p className="mt-2 text-sm leading-relaxed text-text-secondary">
              {comparison.chooseCompetitor}
            </p>
          </div>
          <div className="mk-card border border-primary/25 bg-primary/5 px-6 py-5">
            <h3 className="text-base font-semibold text-primary-light">Choose mokaid if…</h3>
            <p className="mt-2 text-sm leading-relaxed text-text-secondary">
              {comparison.chooseMokaid}
            </p>
          </div>
        </div>
      </section>

      <FaqSection items={comparison.faq} />

      {otherComparisons.length > 0 && (
        <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="more-heading">
          <h2 id="more-heading" className="mk-seo-display text-xl font-bold">
            More comparisons
          </h2>
          <div className="mt-5 flex flex-wrap gap-2.5">
            {otherComparisons.map((c) => (
              <a
                key={c.slug}
                href={`/compare/${c.slug}`}
                className="rounded-full border border-border bg-surface px-4 py-2 text-sm text-text-secondary transition-colors hover:border-primary/30 hover:text-text"
              >
                mokaid vs {c.competitor}
              </a>
            ))}
          </div>
        </section>
      )}

      <section className="mx-auto max-w-4xl px-4 py-4 text-center sm:px-6">
        <Link to="/signup">
          <Button className="min-h-11 px-6 shadow-glow">
            Try mokaid free <ArrowRight size={15} />
          </Button>
        </Link>
      </section>

      <CtaBanner />
    </MarketingLayout>
  );
}
