import {
  Breadcrumbs,
  CtaBanner,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { glossaryTerms } from "@/data/seo/glossary";
import { breadcrumbJsonLd, canonicalUrl, SITE } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

const breadcrumbs = [
  { name: "Home", path: "/" },
  { name: "Glossary", path: "/glossary" },
];

export function GlossaryPage() {
  useSeo({
    title: "AI Workforce Glossary — AI Employees, Agents & Key Terms | mokaid",
    description:
      "Clear, quotable definitions of AI workforce terms: AI employee, AI agent, digital worker, approval gate, human-in-the-loop, MCP, and more.",
    path: "/glossary",
    jsonLd: [
      breadcrumbJsonLd(breadcrumbs),
      {
        "@context": "https://schema.org",
        "@type": "DefinedTermSet",
        "@id": `${SITE.url}/glossary#termset`,
        name: "AI Workforce Glossary",
        url: canonicalUrl("/glossary"),
        hasDefinedTerm: glossaryTerms.map((term) => ({
          "@type": "DefinedTerm",
          "@id": `${SITE.url}/glossary#${term.slug}`,
          name: term.term,
          description: term.definition,
        })),
      },
    ],
  });

  return (
    <MarketingLayout>
      <Breadcrumbs items={breadcrumbs} />

      <section className="mx-auto max-w-4xl px-4 pb-8 pt-12 text-center sm:px-6">
        <h1 className="mk-seo-display text-4xl font-bold leading-tight sm:text-5xl">
          AI Workforce Glossary
        </h1>
        <p className="mx-auto mt-5 max-w-2xl text-lg leading-relaxed text-text-secondary">
          The vocabulary of the AI workforce, defined precisely enough to quote.
        </p>
      </section>

      <section className="mx-auto max-w-3xl px-4 py-10 sm:px-6">
        <div className="space-y-5">
          {glossaryTerms.map((term) => (
            <div key={term.slug} id={term.slug} className="mk-card scroll-mt-24 border border-border px-6 py-6">
              <h2 className="mk-seo-display text-xl font-semibold text-text">{term.term}</h2>
              <p className="mt-3 leading-relaxed text-text">{term.definition}</p>
              <p className="mt-3 text-sm leading-relaxed text-text-secondary">{term.detail}</p>
              {term.related && term.related.length > 0 && (
                <p className="mt-3 text-xs text-text-muted">
                  Related:{" "}
                  {term.related.map((slug, i) => {
                    const relatedTerm = glossaryTerms.find((t) => t.slug === slug);
                    if (!relatedTerm) return null;
                    return (
                      <span key={slug}>
                        {i > 0 && ", "}
                        <a
                          href={`#${slug}`}
                          className="text-primary-light underline underline-offset-2 hover:text-text"
                        >
                          {relatedTerm.term}
                        </a>
                      </span>
                    );
                  })}
                </p>
              )}
            </div>
          ))}
        </div>
      </section>

      <CtaBanner />
    </MarketingLayout>
  );
}
