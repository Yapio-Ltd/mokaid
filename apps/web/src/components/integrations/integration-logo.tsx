import { useState } from "react";
import { cn } from "@/lib/cn";

/** Bundled overrides only when S3/API asset is known-bad or missing. */
const staticLogoOverrides: Record<string, string> = {
  linear: "/logos/brands/linear.svg",
  // Email connectors render in onboarding before the catalog loads — never
  // depend on /api/integrations/logos/:key for these.
  gmail: "/logos/brands/gmail.svg",
  outlook: "/logos/brands/outlook.svg",
};

const whiteLogoOnDark = new Set(["github"]);

export function IntegrationLogo({
  providerKey,
  logoUrl,
  name,
  size = "md",
  onDark = false,
}: {
  providerKey: string;
  logoUrl?: string | null;
  name: string;
  size?: "sm" | "md";
  /** Lighten monochrome logos (e.g. GitHub) for dark UI surfaces */
  onDark?: boolean;
}) {
  const [failed, setFailed] = useState(false);
  const sizeClass = size === "sm" ? "h-9 w-9" : "h-10 w-10";
  const src =
    staticLogoOverrides[providerKey] ??
    logoUrl ??
    `/api/integrations/logos/${providerKey}`;

  const initials = name
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0])
    .join("")
    .toUpperCase();

  if (failed) {
    return (
      <span
        className={cn(
          "flex shrink-0 items-center justify-center text-xs font-semibold text-text-muted",
          sizeClass,
        )}
      >
        {initials}
      </span>
    );
  }

  return (
    <img
      src={src}
      alt={name}
      className={cn(
        "shrink-0 object-contain",
        sizeClass,
        onDark && whiteLogoOnDark.has(providerKey) && "brightness-0 invert",
      )}
      onError={() => setFailed(true)}
    />
  );
}
