import { HeroScene } from "@/components/landing/hero-scene";
import { OfficeTour } from "@/components/landing/office-tour";
import { AgentTour } from "@/components/landing/agent-tour";
import { McpConnectors } from "@/components/landing/mcp-connectors";
import { FinalCta } from "@/components/landing/final-cta";
import { SiteFooter } from "@/components/landing/site-footer";
import { SiteHeader } from "@/components/marketing/site-header";
import { WhyMokaid } from "@/components/landing/why-mokaid";
import { ORGANIZATION_JSONLD, SITE, SOFTWARE_JSONLD } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

/** Public sections mount with the page so deep links always have a target. */
export function LandingPage() {
  useSeo({
    title: SITE.defaultTitle,
    description: SITE.defaultDescription,
    path: "/",
    jsonLd: [
      SOFTWARE_JSONLD,
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "@id": `${SITE.url}/#website`,
        name: SITE.name,
        url: SITE.url,
        publisher: ORGANIZATION_JSONLD["@id"] ? { "@id": ORGANIZATION_JSONLD["@id"] } : undefined,
      },
    ],
  });

  return (
    <div className="mk-landing min-h-screen bg-bg-deep text-text">
      <SiteHeader />
      <main id="main-content" tabIndex={-1}>
        <HeroScene />
        <OfficeTour />
        <WhyMokaid />
        <AgentTour />
        <McpConnectors />
        <section className="px-5 py-16 sm:py-24">
          <figure className="mx-auto max-w-3xl text-center">
            <blockquote className="text-xl font-medium leading-relaxed tracking-tight text-text sm:text-2xl md:text-3xl">
              "We onboarded three AI agents in an afternoon. They now handle research, first drafts
              and QA while the team focuses on decisions. It feels like the office grew overnight."
            </blockquote>
            <figcaption className="mt-6 text-sm text-text-secondary">
              <span className="font-semibold text-text">Tom Jami</span>, Founder at Yapio
            </figcaption>
          </figure>
        </section>
        <FinalCta />
      </main>
      <SiteFooter />
    </div>
  );
}
