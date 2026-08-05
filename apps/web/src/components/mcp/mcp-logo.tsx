import { useEffect, useMemo, useState } from "react";
import { cn } from "@/lib/cn";

const categoryColors: Record<string, string> = {
  productivity: "#fbbf24",
  development: "#60a5fa",
  communication: "#22d3ee",
  crm: "#f87171",
  finance: "#a3e635",
  cloud: "#818cf8",
  database: "#34d399",
  ai: "#7c5cff",
  search: "#f472b6",
  browser: "#fb923c",
  design: "#e879f9",
  docs: "#2dd4bf",
  storage: "#94a3b8",
  monitoring: "#facc15",
};

export function categoryColor(category: string): string {
  return categoryColors[category] ?? "#7c5cff";
}

/** Catalog logos bundled in `public/logos/mcp/<slug>.svg` (always available in prod). */
export function staticMcpLogoUrl(slug: string | null | undefined): string | null {
  if (!slug) return null;
  return `/logos/mcp/${slug}.svg`;
}

export function McpLogo({
  logoUrl,
  logoSlug,
  name,
  category,
  size = "md",
}: {
  logoUrl?: string | null;
  logoSlug?: string | null;
  name: string;
  category: string;
  size?: "sm" | "md" | "lg";
}) {
  const sizeClass = size === "sm" ? "h-8 w-8" : size === "lg" ? "h-12 w-12" : "h-10 w-10";
  const imgClass = size === "sm" ? "h-6 w-6" : size === "lg" ? "h-9 w-9" : "h-7 w-7";
  const color = categoryColor(category);

  // Prefer API logos (`/api/mcp/logos/...`) — full-color brand assets from
  // `priv/integration-logos/`. Static `/logos/mcp/*.svg` are monochrome white
  // Simple Icons used only for the marketing landing (dark marks on dark UI);
  // use them as fallback, then initials.
  const candidates = useMemo(() => {
    const urls: string[] = [];
    if (logoUrl) urls.push(logoUrl);
    const staticUrl = staticMcpLogoUrl(logoSlug);
    if (staticUrl && staticUrl !== logoUrl) urls.push(staticUrl);
    return urls;
  }, [logoSlug, logoUrl]);

  const [index, setIndex] = useState(0);

  useEffect(() => {
    setIndex(0);
  }, [candidates]);

  const initials = useMemo(
    () =>
      name
        .split(/\s+/)
        .slice(0, 2)
        .map((w) => w[0])
        .join("")
        .toUpperCase(),
    [name],
  );

  if (index >= candidates.length) {
    return (
      <span
        className={cn(
          "flex shrink-0 items-center justify-center rounded-md text-xs font-bold text-white",
          sizeClass,
        )}
        style={{ backgroundColor: color }}
      >
        {initials}
      </span>
    );
  }

  return (
    <span className={cn("flex shrink-0 items-center justify-center", sizeClass)}>
      <img
        src={candidates[index]}
        alt={name}
        className={cn(imgClass, "object-contain")}
        onError={() => setIndex((i) => i + 1)}
      />
    </span>
  );
}
