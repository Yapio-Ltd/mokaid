import { Coins, Infinity as InfinityIcon } from "lucide-react";
import { Link } from "@tanstack/react-router";
import { useBillingOverview } from "@/api/hooks";
import { formatNumber } from "@/lib/format";
import { cn } from "@/lib/cn";

/**
 * Live AI-credit balance pill for the topbar. Updates in realtime as runs
 * consume credits (the billing overview cache is patched by the workspace
 * channel), so users see their consumption tick down as agents work.
 */
export function CreditBalance() {
  const { data } = useBillingOverview();
  const credits = data?.data.credits;
  if (!credits) return null;

  if (credits.unlimited) {
    return (
      <Link
        to="/billing"
        className="flex items-center gap-1.5 rounded-full border border-border bg-surface-raised px-2.5 py-1 text-[11px] font-semibold text-text-secondary transition-colors hover:border-primary/40"
        title="Unlimited AI credits"
      >
        <Coins size={12} className="text-primary-light" />
        <InfinityIcon size={13} />
      </Link>
    );
  }

  const spendable = credits.spendable;
  const low = spendable <= 100;
  const negative = spendable < 0;

  return (
    <Link
      to="/billing"
      className={cn(
        "flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-semibold transition-colors",
        negative
          ? "border-danger/40 bg-danger-muted text-danger"
          : low
            ? "border-warning/40 bg-warning-muted text-warning"
            : "border-border bg-surface-raised text-text-secondary hover:border-primary/40",
      )}
      title={`${formatNumber(spendable)} AI credits remaining — click to manage`}
    >
      <Coins size={12} className={cn(!negative && !low && "text-primary-light")} />
      {formatNumber(spendable)}
    </Link>
  );
}
