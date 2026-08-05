import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

/**
 * Standard app page header — neon violet title with an animated glowing
 * underline, optional subtitle and right-aligned actions. Keeps every page
 * aligned with the sidebar/topbar design language.
 */
export function PageHeader({
  title,
  subtitle,
  actions,
  className,
}: {
  title: ReactNode;
  subtitle?: ReactNode;
  actions?: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("mk-page-head flex flex-wrap items-start justify-between gap-3", className)}>
      <div className="min-w-0">
        <h1 className="mk-page-title text-xl font-bold tracking-tight text-text">{title}</h1>
        {subtitle && <p className="mt-1 text-xs text-text-muted">{subtitle}</p>}
      </div>
      {actions && <div className="flex shrink-0 flex-wrap items-center gap-2">{actions}</div>}
    </div>
  );
}
