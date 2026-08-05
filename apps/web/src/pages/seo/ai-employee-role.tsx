import { Link, useParams } from "@tanstack/react-router";
import { ArrowRight, Check, Plug } from "lucide-react";
import {
  Breadcrumbs,
  CtaBanner,
  FaqSection,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { Button } from "@/components/ui/button";
import { getRole, roles } from "@/data/seo/roles";
import { breadcrumbJsonLd, faqJsonLd } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

function RoleNotFound() {
  useSeo({
    title: "Role not found | mokaid",
    description: "This AI employee role does not exist.",
    path: "/ai-employees",
  });
  return (
    <MarketingLayout>
      <section className="mx-auto max-w-3xl px-4 py-24 text-center sm:px-6">
        <h1 className="mk-seo-display text-3xl font-bold">Role not found</h1>
        <p className="mt-3 text-text-secondary">
          This role does not exist (yet). Browse the AI employees you can hire today.
        </p>
        <a href="/ai-employees" className="mt-6 inline-block">
          <Button className="min-h-11 px-6">
            Browse AI employees <ArrowRight size={15} />
          </Button>
        </a>
      </section>
    </MarketingLayout>
  );
}

export function AiEmployeeRolePage() {
  const { slug } = useParams({ strict: false }) as { slug?: string };
  const role = slug ? getRole(slug) : undefined;

  if (!role) return <RoleNotFound />;
  return <RoleContent slug={role.slug} />;
}

function RoleContent({ slug }: { slug: string }) {
  const role = getRole(slug)!;
  const path = `/ai-employees/${role.slug}`;
  const breadcrumbs = [
    { name: "Home", path: "/" },
    { name: "AI Employees", path: "/ai-employees" },
    { name: role.shortName, path },
  ];

  useSeo({
    title: role.title,
    description: role.metaDescription,
    path,
    jsonLd: [breadcrumbJsonLd(breadcrumbs), faqJsonLd(role.faq)],
  });

  const otherRoles = roles.filter((r) => r.slug !== role.slug).slice(0, 3);

  return (
    <MarketingLayout>
      <Breadcrumbs items={breadcrumbs} />

      <section className="mx-auto max-w-4xl px-4 pb-8 pt-12 sm:px-6">
        <p className="text-xs font-semibold uppercase tracking-[0.2em] text-primary-light">
          {role.shortName}
        </p>
        <h1 className="mk-seo-display mt-3 text-3xl font-bold leading-tight sm:text-4xl">
          {role.h1}
        </h1>
        <p className="mt-5 text-lg leading-relaxed text-text-secondary">{role.intro}</p>
        <div className="mt-7">
          <Link to="/signup">
            <Button className="min-h-11 px-6 shadow-glow">
              Hire this AI employee <ArrowRight size={15} />
            </Button>
          </Link>
        </div>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-6 sm:px-6">
        <div className="mk-card border border-primary/15 px-6 py-5">
          <h2 className="text-sm font-semibold uppercase tracking-wide text-text-muted">
            Definition
          </h2>
          <p className="mt-2 leading-relaxed text-text">{role.definition}</p>
        </div>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="duties-heading">
        <h2 id="duties-heading" className="mk-seo-display text-2xl font-bold">
          What this AI employee does
        </h2>
        <ul className="mt-5 space-y-3">
          {role.responsibilities.map((item) => (
            <li key={item} className="flex items-start gap-3 text-text-secondary">
              <Check size={17} className="mt-1 shrink-0 text-primary-light" aria-hidden />
              <span>{item}</span>
            </li>
          ))}
        </ul>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="tools-heading">
        <h2 id="tools-heading" className="mk-seo-display text-2xl font-bold">
          Works with your tools
        </h2>
        <div className="mt-5 flex flex-wrap gap-2.5">
          {role.integrations.map((tool) => (
            <span
              key={tool}
              className="inline-flex items-center gap-1.5 rounded-full border border-border bg-surface px-3.5 py-1.5 text-sm text-text-secondary"
            >
              <Plug size={13} className="text-primary-light" aria-hidden />
              {tool}
            </span>
          ))}
        </div>
      </section>

      <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="outcomes-heading">
        <h2 id="outcomes-heading" className="mk-seo-display text-2xl font-bold">
          What you get
        </h2>
        <div className="mt-5 grid gap-4 sm:grid-cols-3">
          {role.outcomes.map((item) => (
            <div key={item} className="mk-card border border-border px-5 py-5">
              <p className="text-sm leading-relaxed text-text-secondary">{item}</p>
            </div>
          ))}
        </div>
      </section>

      <FaqSection items={role.faq} heading={`${role.shortName} — FAQ`} />

      <section className="mx-auto max-w-4xl px-4 py-8 sm:px-6" aria-labelledby="more-roles-heading">
        <h2 id="more-roles-heading" className="mk-seo-display text-xl font-bold">
          Other AI employees to hire
        </h2>
        <div className="mt-5 grid gap-4 sm:grid-cols-3">
          {otherRoles.map((r) => (
            <a
              key={r.slug}
              href={`/ai-employees/${r.slug}`}
              className="mk-card mk-card-interactive group border border-border px-5 py-4 transition-colors hover:border-primary/30"
            >
              <h3 className="text-base font-semibold text-text group-hover:text-primary-light">
                {r.shortName}
              </h3>
              <span className="mt-2 inline-flex items-center gap-1 text-sm text-primary-light">
                View role <ArrowRight size={13} />
              </span>
            </a>
          ))}
        </div>
      </section>

      <CtaBanner />
    </MarketingLayout>
  );
}
