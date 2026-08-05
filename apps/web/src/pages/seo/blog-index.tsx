import { ArrowRight } from "lucide-react";
import {
  Breadcrumbs,
  CtaBanner,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { blogPosts, formatPostDate } from "@/data/seo/blog";
import { breadcrumbJsonLd, canonicalUrl, SITE } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

const breadcrumbs = [
  { name: "Home", path: "/" },
  { name: "Blog", path: "/blog" },
];

export function BlogIndexPage() {
  useSeo({
    title: "The AI Workforce Blog — AI Employees, Agents & the Future of Work | mokaid",
    description:
      "Guides and thinking on AI employees, AI agents, and running an AI workforce: definitions, hiring playbooks, management practices, and category deep-dives.",
    path: "/blog",
    jsonLd: [
      breadcrumbJsonLd(breadcrumbs),
      {
        "@context": "https://schema.org",
        "@type": "Blog",
        "@id": `${SITE.url}/blog#blog`,
        name: "The AI Workforce Blog",
        url: canonicalUrl("/blog"),
        publisher: { "@id": `${SITE.url}/#organization` },
      },
    ],
  });

  return (
    <MarketingLayout>
      <Breadcrumbs items={breadcrumbs} />

      <section className="mx-auto max-w-4xl px-4 pb-8 pt-12 text-center sm:px-6">
        <h1 className="mk-seo-display text-4xl font-bold leading-tight sm:text-5xl">
          The AI Workforce Blog
        </h1>
        <p className="mx-auto mt-5 max-w-2xl text-lg leading-relaxed text-text-secondary">
          Definitions, playbooks, and honest thinking about AI employees and the teams that
          manage them.
        </p>
      </section>

      <section className="mx-auto max-w-3xl px-4 py-10 sm:px-6">
        <div className="space-y-4">
          {blogPosts.map((post) => (
            <a
              key={post.slug}
              href={`/blog/${post.slug}`}
              className="mk-card mk-card-interactive group block border border-border px-6 py-6 transition-colors hover:border-primary/30"
            >
              <div className="flex flex-wrap items-center gap-2 text-xs text-text-muted">
                <time dateTime={post.publishDate}>{formatPostDate(post.publishDate)}</time>
                <span aria-hidden="true">·</span>
                <span>{post.tags.join(", ")}</span>
              </div>
              <h2 className="mk-seo-display mt-2 text-xl font-semibold text-text group-hover:text-primary-light">
                {post.title}
              </h2>
              <p className="mt-2 text-sm leading-relaxed text-text-secondary">
                {post.description}
              </p>
              <span className="mt-3 inline-flex items-center gap-1 text-sm font-medium text-primary-light">
                Read article <ArrowRight size={14} />
              </span>
            </a>
          ))}
        </div>
      </section>

      <CtaBanner />
    </MarketingLayout>
  );
}
