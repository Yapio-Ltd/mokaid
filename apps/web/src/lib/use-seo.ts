import { useLayoutEffect } from "react";
import { canonicalUrl, ORGANIZATION_JSONLD, SITE } from "@/lib/seo";

export interface SeoOptions {
  title: string;
  description: string;
  /** Route path used for the canonical URL, e.g. "/ai-employees". */
  path: string;
  ogType?: "website" | "article";
  ogImage?: string;
  /** Extra JSON-LD objects. Organization is always included. */
  jsonLd?: object[];
  articleMeta?: { publishedTime: string; modifiedTime?: string };
}

function upsertMeta(attr: "name" | "property", key: string, content: string) {
  let el = document.head.querySelector(`meta[${attr}="${key}"]`);
  if (!el) {
    el = document.createElement("meta");
    el.setAttribute(attr, key);
    document.head.appendChild(el);
  }
  el.setAttribute("content", content);
}

function removeMeta(attr: "name" | "property", key: string) {
  document.head.querySelector(`meta[${attr}="${key}"]`)?.remove();
}

/**
 * Sets document head metadata (title, description, canonical, Open Graph,
 * Twitter, JSON-LD) for a public page. The post-build prerender step snapshots
 * the rendered DOM, so everything written here ends up in the static HTML that
 * search engines and social crawlers see.
 */
export function useSeo(options: SeoOptions) {
  const { title, description, path, ogType = "website", ogImage = SITE.ogImage } = options;
  // Serialize for the dependency array: options object identity changes every render.
  const jsonLdSerialized = JSON.stringify([ORGANIZATION_JSONLD, ...(options.jsonLd ?? [])]);
  const articleSerialized = JSON.stringify(options.articleMeta ?? null);

  useLayoutEffect(() => {
    const canonical = canonicalUrl(path);

    document.title = title;
    upsertMeta("name", "description", description);

    let link = document.head.querySelector('link[rel="canonical"]');
    if (!link) {
      link = document.createElement("link");
      link.setAttribute("rel", "canonical");
      document.head.appendChild(link);
    }
    link.setAttribute("href", canonical);

    upsertMeta("property", "og:type", ogType);
    upsertMeta("property", "og:url", canonical);
    upsertMeta("property", "og:site_name", SITE.name);
    upsertMeta("property", "og:title", title);
    upsertMeta("property", "og:description", description);
    upsertMeta("property", "og:image", ogImage);
    upsertMeta("property", "og:image:width", "1200");
    upsertMeta("property", "og:image:height", "630");
    upsertMeta("name", "twitter:card", "summary_large_image");
    upsertMeta("name", "twitter:site", SITE.twitterHandle);
    upsertMeta("name", "twitter:title", title);
    upsertMeta("name", "twitter:description", description);
    upsertMeta("name", "twitter:image", ogImage);

    const articleMeta = articleSerialized === "null" ? null : JSON.parse(articleSerialized);
    if (articleMeta) {
      upsertMeta("property", "article:published_time", articleMeta.publishedTime);
      if (articleMeta.modifiedTime) {
        upsertMeta("property", "article:modified_time", articleMeta.modifiedTime);
      }
    } else {
      removeMeta("property", "article:published_time");
      removeMeta("property", "article:modified_time");
    }

    document.head.querySelectorAll("script[data-seo-jsonld]").forEach((el) => el.remove());
    for (const obj of JSON.parse(jsonLdSerialized) as object[]) {
      const script = document.createElement("script");
      script.type = "application/ld+json";
      script.setAttribute("data-seo-jsonld", "");
      script.textContent = JSON.stringify(obj);
      document.head.appendChild(script);
    }
  }, [title, description, path, ogType, ogImage, jsonLdSerialized, articleSerialized]);
}
