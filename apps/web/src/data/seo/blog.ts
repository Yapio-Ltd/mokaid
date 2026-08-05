import { marked } from "marked";

export interface BlogPost {
  slug: string;
  title: string;
  description: string;
  publishDate: string; // ISO date
  author: string;
  tags: string[];
  keyTakeaway: string;
  html: string;
}

const rawPosts = import.meta.glob("../../content/blog/*.md", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

/** Minimal frontmatter parser for our known, flat schema (quoted strings, dates, JSON arrays). */
function parseFrontmatter(raw: string): { data: Record<string, string>; body: string } {
  const match = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(raw);
  if (!match) return { data: {}, body: raw };
  const data: Record<string, string> = {};
  for (const line of match[1].split(/\r?\n/)) {
    const idx = line.indexOf(":");
    if (idx === -1) continue;
    const key = line.slice(0, idx).trim();
    let value = line.slice(idx + 1).trim();
    if (value.startsWith('"') && value.endsWith('"')) value = value.slice(1, -1);
    data[key] = value;
  }
  return { data, body: raw.slice(match[0].length) };
}

function parseTags(value: string | undefined): string[] {
  if (!value) return [];
  try {
    const parsed = JSON.parse(value);
    return Array.isArray(parsed) ? parsed.map(String) : [];
  } catch {
    return [];
  }
}

export const blogPosts: BlogPost[] = Object.entries(rawPosts)
  .map(([path, raw]) => {
    const slug = path.split("/").pop()!.replace(/\.md$/, "");
    const { data, body } = parseFrontmatter(raw);
    return {
      slug,
      title: data.title ?? slug,
      description: data.description ?? "",
      publishDate: data.publishDate ?? "2026-01-01",
      author: data.author ?? "The mokaid Team",
      tags: parseTags(data.tags),
      keyTakeaway: data.keyTakeaway ?? "",
      html: marked.parse(body, { async: false }),
    };
  })
  .sort((a, b) => b.publishDate.localeCompare(a.publishDate));

export function getBlogPost(slug: string): BlogPost | undefined {
  return blogPosts.find((p) => p.slug === slug);
}

export function formatPostDate(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}
