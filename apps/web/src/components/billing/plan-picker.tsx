import { Check, Coins } from "lucide-react";
import type { BillingPlanSummary } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";
import { formatCents, formatNumber } from "@/lib/format";

const tagline: Record<string, string> = {
  free: "Try your first AI employee",
  starter: "For solo builders",
  professional: "For growing teams",
  business: "For companies at scale",
  enterprise: "Custom for your organization",
};

export type BillingCycle = "monthly" | "yearly";

/** Monthly/yearly switch — yearly bills 10 months for 12 ("2 months free"). */
export function BillingCycleToggle({
  cycle,
  onChange,
}: {
  cycle: BillingCycle;
  onChange: (cycle: BillingCycle) => void;
}) {
  return (
    <div className="flex items-center justify-center gap-1 rounded-full border border-border bg-surface-raised p-1 text-xs font-semibold">
      {(["monthly", "yearly"] as const).map((option) => (
        <button
          key={option}
          type="button"
          onClick={() => onChange(option)}
          className={cn(
            "flex items-center gap-1.5 rounded-full px-3 py-1.5 transition-colors",
            cycle === option
              ? "bg-primary text-white shadow-sm"
              : "text-text-muted hover:text-text",
          )}
        >
          {option === "monthly" ? "Monthly" : "Yearly"}
          {option === "yearly" && (
            <span
              className={cn(
                "rounded-full px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-wide",
                cycle === "yearly" ? "bg-white/20 text-white" : "bg-success/15 text-success",
              )}
            >
              2 months free
            </span>
          )}
        </button>
      ))}
    </div>
  );
}

/**
 * The real plan catalog as selectable cards — used both in onboarding and the
 * "Manage plan" dialog. Highlights the monthly AI-credit grant (the metered
 * currency) and the AI-employee cap. Enterprise routes to sales.
 */
export function PlanPicker({
  plans,
  currentKey,
  pendingKey,
  onChoose,
  compact = false,
  cycle = "monthly",
}: {
  plans: BillingPlanSummary[];
  currentKey?: string | null;
  pendingKey?: string | null;
  onChoose: (planKey: string) => void;
  compact?: boolean;
  cycle?: BillingCycle;
}) {
  return (
    <div className={cn("grid gap-3", compact ? "sm:grid-cols-2 lg:grid-cols-5" : "sm:grid-cols-2 lg:grid-cols-3")}>
      {plans.map((plan) => {
        const isCurrent = plan.key === currentKey;
        const isEnterprise = plan.key === "enterprise";
        const featured = plan.key === "professional";
        const credits = plan.limits?.credits_monthly ?? 0;
        const agents = plan.limits?.agents ?? 0;

        return (
          <div
            key={plan.key}
            className={cn(
              "flex flex-col rounded-xl border p-4 transition-colors",
              isCurrent
                ? "border-primary/60 bg-primary-muted/20"
                : featured
                  ? "border-primary/30 hover:border-primary/50"
                  : "border-border hover:border-border-strong",
            )}
          >
            <div className="flex items-center justify-between">
              <p className="text-sm font-bold text-text">{plan.name}</p>
              {featured && (
                <span className="rounded-full bg-primary/15 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-wide text-primary-light">
                  Popular
                </span>
              )}
            </div>
            <p className="text-[10px] text-text-muted">{tagline[plan.key] ?? ""}</p>

            <p className="mt-2 text-xl font-bold text-text">
              {isEnterprise ? (
                "Custom"
              ) : plan.price_cents_monthly === 0 ? (
                "Free"
              ) : cycle === "yearly" ? (
                <>
                  {formatCents(Math.round(plan.price_cents_yearly / 12))}
                  <span className="text-[11px] font-normal text-text-muted"> /mo</span>
                  <span className="block text-[10px] font-normal text-text-muted">
                    {formatCents(plan.price_cents_yearly)} billed yearly
                  </span>
                </>
              ) : (
                <>
                  {formatCents(plan.price_cents_monthly)}
                  <span className="text-[11px] font-normal text-text-muted"> /mo</span>
                </>
              )}
            </p>

            {/* Headline: credits + agents */}
            <div className="mt-3 space-y-1.5 rounded-lg bg-surface-raised px-2.5 py-2">
              <p className="flex items-center gap-1.5 text-[11px] font-semibold text-text">
                <Coins size={12} className="text-primary-light" />
                {credits === -1 ? "Unlimited credits" : `${formatNumber(credits)} credits / mo`}
              </p>
              <p className="text-[11px] text-text-secondary">
                {agents === -1 ? "Unlimited AI employees" : `${agents} AI employee${agents > 1 ? "s" : ""}`}
              </p>
            </div>

            <ul className="mt-3 flex-1 space-y-1.5">
              {plan.features.slice(2, compact ? 5 : 6).map((f) => (
                <li key={f} className="flex items-start gap-1.5 text-[11px] text-text-secondary">
                  <Check size={11} className="mt-0.5 shrink-0 text-success" />
                  {f}
                </li>
              ))}
            </ul>

            <Button
              size="sm"
              variant={isCurrent ? "secondary" : featured ? "primary" : "secondary"}
              disabled={isCurrent}
              loading={pendingKey === plan.key}
              className="mt-4 w-full"
              onClick={() => onChoose(plan.key)}
            >
              {isCurrent ? "Current plan" : isEnterprise ? "Contact sales" : "Choose"}
            </Button>
          </div>
        );
      })}
    </div>
  );
}
