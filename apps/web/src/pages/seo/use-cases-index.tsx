import { ArrowRight } from "lucide-react";
import {
  Breadcrumbs,
  CtaBanner,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { useCases } from "@/data/seo/useCases";
import { breadcrumbJsonLd } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

const breadcrumbs = [
  { name: "Home", path: "/" },
  { name: "Use Cases", path: "/use-cases" },
];

export function UseCasesIndexPage() {
  useSeo({
    title: "AI Employee Use Cases — Startups, Agencies, Ecommerce & More | mokaid",
    description:
      "How teams use mokaid's AI employees: startups scaling without headcount, agencies protecting margin, ecommerce automating support, and solo founders building leverage.",
    path: "/use-cases",
    jsonLd: [breadcrumbJsonLd(breadcrumbs)],
  });

  return (
    <MarketingLayout>
      <Breadcrumbs items={breadcrumbs} />

      <section className="mx-auto max-w-4xl px-4 pb-8 pt-12 text-center sm:px-6">
        <h1 className="mk-seo-display text-4xl font-bold leading-tight sm:text-5xl">
          AI employees, put to work
        </h1>
        <p className="mx-auto mt-5 max-w-2xl text-lg leading-relaxed text-text-secondary">
          Different teams hire AI employees for different jobs. Find your situation and see
          which roles to hire first.
        </p>
      </section>

      <section className="mx-auto max-w-5xl px-4 py-10 sm:px-6">
        <div className="grid gap-4 sm:grid-cols-2">
          {useCases.map((useCase) => (
            <a
              key={useCase.slug}
              href={`/use-cases/${useCase.slug}`}
              className="mk-card mk-card-interactive group border border-border px-6 py-6 transition-colors hover:border-primary/30"
            >
              <h2 className="mk-seo-display text-xl font-semibold text-text group-hover:text-primary-light">
                {useCase.shortName}
              </h2>
              <p className="mt-2 line-clamp-3 text-sm leading-relaxed text-text-secondary">
                {useCase.intro}
              </p>
              <span className="mt-4 inline-flex items-center gap-1 text-sm font-medium text-primary-light">
                Read the playbook <ArrowRight size={14} />
              </span>
            </a>
          ))}
        </div>
      </section>

      <CtaBanner />
    </MarketingLayout>
  );
}
