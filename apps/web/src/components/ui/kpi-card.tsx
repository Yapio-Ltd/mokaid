import type { ReactNode } from "react";
import { cn } from "@/lib/cn";
import { TrendingDown, TrendingUp } from "lucide-react";
import { Card } from "./card";

interface KpiCardProps {
  label: string;
  value: ReactNode;
  icon?: ReactNode;
  trend?: { value: number; label?: string };
  tone?: "primary" | "success" | "warning" | "danger" | "info" | "default";
  className?: string;
}

const iconTone = {
  primary: "bg-primary-muted text-primary-light",
  success: "bg-success-muted text-success",
  warning: "bg-warning-muted text-warning",
  danger: "bg-danger-muted text-danger",
  info: "bg-info-muted text-info",
  default: "bg-surface-overlay text-text-secondary",
};

export function KpiCard({ label, value, icon, trend, tone = "default", className }: KpiCardProps) {
  return (
    <Card className={cn("flex items-center gap-4 p-4", className)}>
      {icon && (
        <span className={cn("flex h-11 w-11 shrink-0 items-center justify-center rounded-md", iconTone[tone])}>
          {icon}
        </span>
      )}
      <div className="min-w-0 flex-1">
        <p className="truncate text-xs font-medium text-text-muted">{label}</p>
        <div className="mt-0.5 flex items-baseline gap-2">
          <span className="text-2xl font-bold tracking-tight text-text">{value}</span>
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
    </Card>
  );
}
