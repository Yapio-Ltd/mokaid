import { Check, Coins, Crown, Sparkles, Star, Zap } from "lucide-react";
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

const planIcon: Record<string, typeof Zap> = {
  free: Zap,
  starter: Star,
  professional: Crown,
  business: Sparkles,
  enterprise: Crown,
};

export type BillingCycle = "monthly" | "yearly";

export function BillingCycleToggle({
  cycle,
  onChange,
}: {
  cycle: BillingCycle;
  onChange: (cycle: BillingCycle) => void;
}) {
  return (
    <div className="flex items-center gap-1 rounded-full border border-border bg-surface-raised p-1 text-xs font-semibold">
      {(["monthly", "yearly"] as const).map((option) => (
        <button
          key={option}
          type="button"
          onClick={() => onChange(option)}
          className={cn(
            "flex items-center gap-1.5 rounded-full px-4 py-2 transition-all",
            cycle === option
              ? "bg-primary text-white shadow-md shadow-primary/25"
              : "text-text-muted hover:text-text",
          )}
        >
          {option === "monthly" ? "Monthly" : "Yearly"}
          {option === "yearly" && (
            <span
              className={cn(
                "rounded-full px-2 py-0.5 text-[9px] font-bold uppercase tracking-wider",
                cycle === "yearly" ? "bg-white/20 text-white" : "bg-success/15 text-success",
              )}
            >
              Save 17%
            </span>
          )}
        </button>
      ))}
    </div>
  );
}

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
  const sorted = [...plans].sort((a, b) => {
    const order = ["free", "starter", "professional", "business", "enterprise"];
    return order.indexOf(a.key) - order.indexOf(b.key);
  });

  return (
    <div
      className={cn(
        "grid gap-4",
        compact ? "sm:grid-cols-2 lg:grid-cols-5" : "sm:grid-cols-2 xl:grid-cols-5",
      )}
    >
      {sorted.map((plan) => {
        const isCurrent = plan.key === currentKey;
        const isEnterprise = plan.key === "enterprise";
        const featured = plan.key === "professional";
        const credits = plan.limits?.credits_monthly ?? 0;
        const agents = plan.limits?.agents ?? 0;
        const Icon = planIcon[plan.key] ?? Zap;

        return (
          <div
            key={plan.key}
            className={cn(
              "group relative flex flex-col overflow-visible rounded-2xl border p-5 transition-all duration-200",
              featured
                ? "mt-3 border-primary bg-gradient-to-b from-primary/[0.06] to-transparent shadow-lg shadow-primary/10 ring-1 ring-primary/20"
                : isEnterprise
                  ? "border-border bg-gradient-to-b from-surface-raised/60 to-transparent"
                  : isCurrent
                    ? "border-primary/50 bg-primary-muted/15"
                    : "border-border hover:border-primary/30 hover:shadow-md hover:shadow-primary/5",
            )}
          >
            {featured && (
              <div className="absolute -top-3 left-1/2 z-10 -translate-x-1/2 whitespace-nowrap">
                <span className="inline-block rounded-full bg-primary px-3 py-1 text-[10px] font-bold uppercase tracking-wider text-white shadow-md shadow-primary/30">
                  Most Popular
                </span>
              </div>
            )}

            <div className="mb-4">
              <div className="flex items-center gap-2">
                <div
                  className={cn(
                    "flex h-8 w-8 items-center justify-center rounded-lg",
                    featured
                      ? "bg-primary/15 text-primary"
                      : isEnterprise
                        ? "bg-amber-500/15 text-amber-500"
                        : "bg-surface-raised text-text-muted",
                  )}
                >
                  <Icon size={16} />
                </div>
                <div>
                  <p className="text-sm font-bold text-text">{plan.name}</p>
                  <p className="text-[10px] text-text-muted">{tagline[plan.key] ?? ""}</p>
                </div>
              </div>
            </div>

            <div className="mb-5">
              {isEnterprise ? (
                <div>
                  <p className="text-2xl font-bold text-text">Custom</p>
                  <p className="mt-0.5 text-[11px] text-text-muted">Tailored to your needs</p>
                </div>
              ) : plan.price_cents_monthly === 0 ? (
                <div>
                  <p className="text-2xl font-bold text-text">Free</p>
                  <p className="mt-0.5 text-[11px] text-text-muted">No credit card required</p>
                </div>
              ) : cycle === "yearly" ? (
                <div>
                  <div className="flex items-baseline gap-1">
                    <span className="text-3xl font-bold text-text">
                      {formatCents(Math.round(plan.price_cents_yearly / 12))}
                    </span>
                    <span className="text-xs text-text-muted">/mo</span>
                  </div>
                  <p className="mt-0.5 text-[10px] text-text-muted">
                    {formatCents(plan.price_cents_yearly)} billed yearly
                  </p>
                </div>
              ) : (
                <div>
                  <div className="flex items-baseline gap-1">
                    <span className="text-3xl font-bold text-text">
                      {formatCents(plan.price_cents_monthly)}
                    </span>
                    <span className="text-xs text-text-muted">/mo</span>
                  </div>
                </div>
              )}
            </div>

            <div className="mb-5 space-y-2 rounded-xl bg-surface-raised/80 px-3 py-3">
              <div className="flex items-center gap-2">
                <Coins size={13} className="shrink-0 text-primary-light" />
                <span className="text-xs font-semibold text-text">
                  {credits === -1 ? "Unlimited" : formatNumber(credits)} credits
                  {credits !== -1 && <span className="font-normal text-text-muted"> / mo</span>}
                </span>
              </div>
              <div className="flex items-center gap-2">
                <Sparkles size={13} className="shrink-0 text-primary-light" />
                <span className="text-xs text-text-secondary">
                  {agents === -1
                    ? "Unlimited AI employees"
                    : `${agents} AI employee${agents > 1 ? "s" : ""}`}
                </span>
              </div>
            </div>

            <ul className="mb-5 flex-1 space-y-2.5">
              {plan.features.slice(2, compact ? 5 : 7).map((f) => (
                <li key={f} className="flex items-start gap-2 text-[11px] text-text-secondary">
                  <Check
                    size={13}
                    className={cn(
                      "mt-0.5 shrink-0",
                      featured ? "text-primary" : "text-success",
                    )}
                  />
                  <span>{f}</span>
                </li>
              ))}
            </ul>

            <Button
              size="sm"
              variant={isCurrent ? "secondary" : featured ? "primary" : "secondary"}
              disabled={isCurrent}
              loading={pendingKey === plan.key}
              className={cn(
                "w-full",
                featured && !isCurrent && "shadow-md shadow-primary/20",
              )}
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
