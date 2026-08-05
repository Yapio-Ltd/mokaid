import { Link, useParams } from "@tanstack/react-router";
import { ArrowRight, TriangleAlert } from "lucide-react";
import {
  Breadcrumbs,
  CtaBanner,
  FaqSection,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { Button } from "@/components/ui/button";
import { getRole } from "@/data/seo/roles";
import { getUseCase } from "@/data/seo/useCases";
import { breadcrumbJsonLd, faqJsonLd } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

function UseCaseNotFound() {
  useSeo({
    title: "Use case not found | mokaid",
    description: "This use case does not exist.",
    path: "/use-cases",
  });
  return (
    <MarketingLayout>
      <section className="mx-auto max-w-3xl px-4 py-24 text-center sm:px-6">
        <h1 className="mk-seo-display text-3xl font-bold">Use case not found</h1>
        <p className="mt-3 text-text-secondary">Browse how teams put AI employees to work.</p>
        <a href="/use-cases" className="mt-6 inline-block">
          <Button className="min-h-11 px-6">
            Browse use cases <ArrowRight size={15} />
          </Button>
        </a>
      </section>
    </MarketingLayout>
  );
}

export function UseCaseDetailPage() {
  const { slug } = useParams({ strict: false }) as { slug?: string };
  const useCase = slug ? getUseCase(slug) : undefined;

  if (!useCase) return <UseCaseNotFound />;
  return <UseCaseContent slug={useCase.slug} />;
}

function UseCaseContent({ slug }: { slug: string }) {
  const useCase = getUseCase(slug)!;
  const path = `/use-cases/${useCase.slug}`;
  const breadcrumbs = [
    { name: "Home", path: "/" },
    { name: "Use Cases", path: "/use-cases" },
    { name: useCase.shortName, path },
  ];

  useSeo({
    title: useCase.title,
    description: useCase.metaDescription,
    path,
    jsonLd: [breadcrumbJsonLd(breadcrumbs), faqJsonLd(useCase.faq)],
  });

  const recommendedRoles = useCase.recommendedRoles
    .map((roleSlug) => getRole(roleSlug))
    .filter((r) => r !== undefined);

  return (
    <MarketingLayout>
      <Breadcrumbs items={breadcrumbs} />

      <section className="mx-auto max-w-4xl px-4 pb-8 pt-12 sm:px-6">
        <p className="text-xs font-semibold uppercase tracking-[0.2em] text-primary-light">
          {useCase.shortName}
        </p>
        <h1 className="mk-seo-display mt-3 text-3xl font-bold leading-tight sm:text-4xl">
          {useCase.h1}
        </h1>
        <p className="mt-5 text-lg leading-relaxed text-text-secondary">{useCase.intro}</p>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="pains-heading">
        <h2 id="pains-heading" className="mk-seo-display text-2xl font-bold">
          Sound familiar?
        </h2>
        <ul className="mt-5 grid gap-3 sm:grid-cols-2">
          {useCase.painPoints.map((pain) => (
            <li
              key={pain}
              className="mk-card flex items-start gap-3 border border-border px-5 py-4 text-sm leading-relaxed text-text-secondary"
            >
              <TriangleAlert size={16} className="mt-0.5 shrink-0 text-warning" aria-hidden />
              {pain}
            </li>
          ))}
        </ul>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="solution-heading">
        <h2 id="solution-heading" className="mk-seo-display text-2xl font-bold">
          How mokaid changes it
        </h2>
        <p className="mt-4 leading-relaxed text-text-secondary">{useCase.solution}</p>
      </section>

      {recommendedRoles.length > 0 && (
        <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="hire-heading">
          <h2 id="hire-heading" className="mk-seo-display text-2xl font-bold">
            Who to hire first
          </h2>
          <div className="mt-5 grid gap-4 sm:grid-cols-3">
            {recommendedRoles.map((role) => (
              <a
                key={role.slug}
                href={`/ai-employees/${role.slug}`}
                className="mk-card mk-card-interactive group border border-border px-5 py-5 transition-colors hover:border-primary/30"
              >
                <h3 className="text-base font-semibold text-text group-hover:text-primary-light">
                  {role.shortName}
                </h3>
                <p className="mt-2 line-clamp-3 text-sm leading-relaxed text-text-secondary">
                  {role.definition}
                </p>
                <span className="mt-3 inline-flex items-center gap-1 text-sm text-primary-light">
                  View role <ArrowRight size={13} />
                </span>
              </a>
            ))}
          </div>
        </section>
      )}

      <FaqSection items={useCase.faq} />

      <section className="mx-auto max-w-4xl px-4 py-4 text-center sm:px-6">
        <Link to="/signup">
          <Button className="min-h-11 px-6 shadow-glow">
            Start free <ArrowRight size={15} />
          </Button>
        </Link>
      </section>

      <CtaBanner />
    </MarketingLayout>
  );
}
