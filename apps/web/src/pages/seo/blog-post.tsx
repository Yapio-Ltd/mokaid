import { useParams } from "@tanstack/react-router";
import { ArrowRight, Lightbulb } from "lucide-react";
import {
  Breadcrumbs,
  CtaBanner,
  MarketingLayout,
} from "@/components/seo/marketing-layout";
import { Button } from "@/components/ui/button";
import { blogPosts, formatPostDate, getBlogPost } from "@/data/seo/blog";
import { breadcrumbJsonLd, canonicalUrl, SITE } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";

function PostNotFound() {
  useSeo({
    title: "Article not found | mokaid",
    description: "This article does not exist.",
    path: "/blog",
  });
  return (
    <MarketingLayout>
      <section className="mx-auto max-w-3xl px-4 py-24 text-center sm:px-6">
        <h1 className="mk-seo-display text-3xl font-bold">Article not found</h1>
        <p className="mt-3 text-text-secondary">Browse the latest from the AI Workforce Blog.</p>
        <a href="/blog" className="mt-6 inline-block">
          <Button className="min-h-11 px-6">
            Browse the blog <ArrowRight size={15} />
          </Button>
        </a>
      </section>
    </MarketingLayout>
  );
}

export function BlogPostPage() {
  const { slug } = useParams({ strict: false }) as { slug?: string };
  const post = slug ? getBlogPost(slug) : undefined;

  if (!post) return <PostNotFound />;
  return <PostContent slug={post.slug} />;
}

function PostContent({ slug }: { slug: string }) {
  const post = getBlogPost(slug)!;
  const path = `/blog/${post.slug}`;
  const breadcrumbs = [
    { name: "Home", path: "/" },
    { name: "Blog", path: "/blog" },
    { name: post.title, path },
  ];

  useSeo({
    title: `${post.title} | mokaid`,
    description: post.description,
    path,
    ogType: "article",
    articleMeta: { publishedTime: post.publishDate },
    jsonLd: [
      breadcrumbJsonLd(breadcrumbs),
      {
        "@context": "https://schema.org",
        "@type": "BlogPosting",
        headline: post.title,
        description: post.description,
        datePublished: post.publishDate,
        author: { "@type": "Organization", name: post.author, url: SITE.url },
        publisher: { "@id": `${SITE.url}/#organization` },
        mainEntityOfPage: canonicalUrl(path),
        image: SITE.ogImage,
      },
    ],
  });

  const related = blogPosts.filter((p) => p.slug !== post.slug).slice(0, 3);

  return (
    <MarketingLayout>
      <Breadcrumbs items={[breadcrumbs[0], breadcrumbs[1]]} />

      <article className="mx-auto max-w-3xl px-4 pb-10 pt-10 sm:px-6">
        <header>
          <div className="flex flex-wrap items-center gap-2 text-xs text-text-muted">
            <time dateTime={post.publishDate}>{formatPostDate(post.publishDate)}</time>
            <span aria-hidden="true">·</span>
            <span>{post.author}</span>
          </div>
          <h1 className="mk-seo-display mt-3 text-3xl font-bold leading-tight sm:text-4xl">
            {post.title}
          </h1>
          {post.keyTakeaway && (
            <div className="mk-card mt-6 flex items-start gap-3 border border-primary/20 bg-primary/5 px-5 py-4">
              <Lightbulb size={18} className="mt-0.5 shrink-0 text-primary-light" aria-hidden />
              <p className="text-sm leading-relaxed text-text">
                <span className="font-semibold">Key takeaway: </span>
                {post.keyTakeaway}
              </p>
            </div>
          )}
        </header>

        <div
          className="mk-prose mt-8"
          // Content is authored in-repo markdown, rendered with marked at build time.
          dangerouslySetInnerHTML={{ __html: post.html }}
        />
      </article>

      {related.length > 0 && (
        <section className="mx-auto max-w-3xl px-4 py-8 sm:px-6" aria-labelledby="related-heading">
          <h2 id="related-heading" className="mk-seo-display text-xl font-bold">
            Keep reading
          </h2>
          <div className="mt-5 space-y-3">
            {related.map((p) => (
              <a
                key={p.slug}
                href={`/blog/${p.slug}`}
                className="mk-card mk-card-interactive group block border border-border px-5 py-4 transition-colors hover:border-primary/30"
              >
                <h3 className="text-base font-semibold text-text group-hover:text-primary-light">
                  {p.title}
                </h3>
                <p className="mt-1 text-sm text-text-secondary">{p.description}</p>
              </a>
            ))}
          </div>
        </section>
      )}

      <CtaBanner />
    </MarketingLayout>
  );
}
