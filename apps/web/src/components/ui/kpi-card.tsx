import type { ReactNode } from "react";
import { cn } from "@/lib/cn";
import { TrendingDown, TrendingUp } from "lucide-react";

interface KpiCardProps {
  label: string;
  value: ReactNode;
  icon?: ReactNode;
  trend?: { value: number; label?: string };
  tone?: "primary" | "success" | "warning" | "danger" | "info" | "default";
  className?: string;
}

const accent = {
  primary: {
    line: "via-primary/60",
    icon: "text-primary-light ring-primary/25 shadow-[0_0_20px_-4px_rgba(124,92,255,0.45)]",
    hover: "hover:shadow-[0_0_28px_-6px_rgba(124,92,255,0.35)]",
    glow: "bg-primary/20",
  },
  success: {
    line: "via-success/60",
    icon: "text-success ring-success/25 shadow-[0_0_20px_-4px_rgba(52,211,153,0.4)]",
    hover: "hover:shadow-[0_0_28px_-6px_rgba(52,211,153,0.3)]",
    glow: "bg-success/15",
  },
  warning: {
    line: "via-warning/60",
    icon: "text-warning ring-warning/25 shadow-[0_0_20px_-4px_rgba(251,191,36,0.4)]",
    hover: "hover:shadow-[0_0_28px_-6px_rgba(251,191,36,0.3)]",
    glow: "bg-warning/15",
  },
  danger: {
    line: "via-danger/60",
    icon: "text-danger ring-danger/25 shadow-[0_0_20px_-4px_rgba(248,113,113,0.4)]",
    hover: "hover:shadow-[0_0_28px_-6px_rgba(248,113,113,0.3)]",
    glow: "bg-danger/15",
  },
  info: {
    line: "via-info/60",
    icon: "text-info ring-info/25 shadow-[0_0_20px_-4px_rgba(96,165,250,0.4)]",
    hover: "hover:shadow-[0_0_28px_-6px_rgba(96,165,250,0.3)]",
    glow: "bg-info/15",
  },
  default: {
    line: "via-white/20",
    icon: "text-text-secondary ring-white/10 shadow-none",
    hover: "hover:shadow-md",
    glow: "bg-white/5",
  },
};

export function KpiCard({ label, value, icon, trend, tone = "default", className }: KpiCardProps) {
  const t = accent[tone];

  return (
    <div
      className={cn(
        "group relative overflow-hidden rounded-2xl border border-white/[0.06]",
        "bg-surface/50 backdrop-blur-md",
        "transition-all duration-300 ease-out",
        "hover:-translate-y-0.5",
        t.hover,
        className,
      )}
    >
      {/* Top luminous hairline */}
      <span
        aria-hidden
        className={cn(
          "pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent to-transparent",
          t.line,
        )}
      />

      <div className="relative flex items-center gap-3.5 px-4 py-3.5">
        {icon && (
          <span className="relative flex shrink-0">
            <span
              aria-hidden
              className={cn(
                "absolute inset-0 scale-150 rounded-full blur-xl opacity-40 transition-opacity duration-300 group-hover:opacity-70",
                t.glow,
              )}
            />
            <span
              className={cn(
                "relative flex h-10 w-10 items-center justify-center rounded-full",
                "bg-bg-deep/60 ring-1 backdrop-blur-sm",
                t.icon,
              )}
            >
              {icon}
            </span>
          </span>
        )}

        <div className="min-w-0 flex-1">
          <p className="truncate text-[10px] font-medium uppercase tracking-[0.15em] text-text-muted">
            {label}
          </p>
          <div className="mt-0.5 flex items-baseline gap-2">
            <span className="text-[1.65rem] font-semibold leading-none tracking-tight tabular-nums text-text">
              {value}
            </span>
            {trend && (
              <span
                className={cn(
                  "inline-flex items-center gap-0.5 text-[11px] font-medium",
                  trend.value >= 0 ? "text-success" : "text-danger",
                )}
              >
                {trend.value >= 0 ? <TrendingUp size={12} /> : <TrendingDown size={12} />}
                {Math.abs(trend.value)}%{trend.label ? ` ${trend.label}` : ""}
              </span>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
