import type { HTMLAttributes } from "react";
import { cn } from "@/lib/cn";

type Tone = "default" | "primary" | "success" | "warning" | "danger" | "info" | "muted";

interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: Tone;
  dot?: boolean;
}

const toneClasses: Record<Tone, string> = {
  default: "bg-surface-overlay text-text-secondary border-border",
  primary: "bg-primary-muted text-primary-light border-primary/25",
  success: "bg-success-muted text-success border-success/25",
  warning: "bg-warning-muted text-warning border-warning/25",
  danger: "bg-danger-muted text-danger border-danger/25",
  info: "bg-info-muted text-info border-info/25",
  muted: "bg-surface-overlay text-text-muted border-border",
};

const dotColor: Record<Tone, string> = {
  default: "bg-text-muted",
  primary: "bg-primary",
  success: "bg-success",
  warning: "bg-warning",
  danger: "bg-danger",
  info: "bg-info",
  muted: "bg-text-muted",
};

export function Badge({ tone = "default", dot, className, children, ...props }: BadgeProps) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11px] font-medium whitespace-nowrap",
        toneClasses[tone],
        className,
      )}
      {...props}
    >
      {dot && <span className={cn("h-1.5 w-1.5 rounded-full", dotColor[tone])} />}
      {children}
    </span>
  );
}
