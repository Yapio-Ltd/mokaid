import { cn } from "@/lib/cn";

interface ProgressBarProps {
  value: number; // 0..100
  tone?: "primary" | "success" | "warning" | "danger" | "info";
  size?: "xs" | "sm" | "md";
  className?: string;
}

const toneClasses = {
  primary: "bg-primary",
  success: "bg-success",
  warning: "bg-warning",
  danger: "bg-danger",
  info: "bg-info",
};

const sizeClasses = { xs: "h-1", sm: "h-1.5", md: "h-2" };

export function ProgressBar({ value, tone = "primary", size = "sm", className }: ProgressBarProps) {
  const clamped = Math.max(0, Math.min(100, value));

  return (
    <div
      role="progressbar"
      aria-valuenow={clamped}
      aria-valuemin={0}
      aria-valuemax={100}
      className={cn("w-full overflow-hidden rounded-full bg-surface-overlay", sizeClasses[size], className)}
    >
      <div
        className={cn("h-full rounded-full transition-all duration-300", toneClasses[tone])}
        style={{ width: `${clamped}%` }}
      />
    </div>
  );
}
