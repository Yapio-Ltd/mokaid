import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

interface EmptyStateProps {
  icon?: ReactNode;
  title: string;
  description?: string;
  action?: ReactNode;
  className?: string;
}

export function EmptyState({ icon, title, description, action, className }: EmptyStateProps) {
  return (
    <div className={cn("flex flex-col items-center justify-center gap-3 py-16 text-center", className)}>
      {icon && (
        <span className="flex h-14 w-14 items-center justify-center rounded-full bg-surface-overlay text-text-muted">
          {icon}
        </span>
      )}
      <div>
        <p className="text-sm font-semibold text-text">{title}</p>
        {description && <p className="mt-1 max-w-sm text-xs text-text-muted">{description}</p>}
      </div>
      {action}
    </div>
  );
}
