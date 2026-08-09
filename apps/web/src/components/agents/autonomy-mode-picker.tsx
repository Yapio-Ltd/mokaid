import { Check, Eye, Rocket, Scale } from "lucide-react";
import type { AgentAutonomyMode } from "@/api/types";
import { cn } from "@/lib/cn";

export const AUTONOMY_MODES: Array<{
  value: AgentAutonomyMode;
  label: string;
  description: string;
  icon: typeof Eye;
}> = [
  {
    value: "supervised",
    label: "Supervised",
    description:
      "Pauses for your approval before any significant action, including content generation.",
    icon: Eye,
  },
  {
    value: "balanced",
    label: "Balanced",
    description:
      "Works freely; pauses only for external actions (emails, posts, sensitive writes).",
    icon: Scale,
  },
  {
    value: "autonomous",
    label: "Autonomous",
    description:
      "Full trust — only critical actions (purchases) still require your go-ahead.",
    icon: Rocket,
  },
];

/** Three-card supervision mode selector, shared by the builder and the profile. */
export function AutonomyModePicker({
  value,
  onChange,
  disabled,
}: {
  value: AgentAutonomyMode;
  onChange: (mode: AgentAutonomyMode) => void;
  disabled?: boolean;
}) {
  return (
    <div className="space-y-1.5">
      {AUTONOMY_MODES.map(({ value: mode, label, description, icon: Icon }) => {
        const active = value === mode;
        return (
          <button
            key={mode}
            type="button"
            disabled={disabled}
            onClick={() => onChange(mode)}
            className={cn(
              "flex w-full items-start gap-3 rounded-xl border p-3 text-left transition-all mk-focus-ring",
              active
                ? "border-primary/60 bg-primary-muted/40"
                : "border-border/60 bg-surface-raised/40 hover:border-primary/30 hover:bg-surface-hover/50",
            )}
          >
            <div
              className={cn(
                "mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-lg",
                active
                  ? "bg-primary/20 text-primary-light"
                  : "bg-surface-raised text-text-muted",
              )}
            >
              <Icon size={14} />
            </div>
            <div className="min-w-0">
              <p
                className={cn(
                  "text-xs font-semibold",
                  active ? "text-primary-light" : "text-text",
                )}
              >
                {label}
                {active && <Check size={11} className="ml-1.5 inline-block" />}
              </p>
              <p className="mt-0.5 text-[11px] leading-relaxed text-text-muted">
                {description}
              </p>
            </div>
          </button>
        );
      })}
    </div>
  );
}
