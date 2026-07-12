import { useEffect, useState } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  Coins,
  CreditCard,
  Download,
  RefreshCw,
  Sparkles,
} from "lucide-react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { useQueryClient } from "@tanstack/react-query";
import { colors } from "@mokaid/design-tokens";
import {
  useBillingOverview,
  useBillingPlans,
  useCreditPacks,
  useCreditsCheckout,
  useInvoices,
  usePlanCheckout,
  useUpdateAutoRecharge,
} from "@/api/hooks";
import type { Invoice } from "@/api/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import {
  BillingCycleToggle,
  PlanPicker,
  type BillingCycle,
} from "@/components/billing/plan-picker";
import { ProgressBar } from "@/components/ui/progress-bar";
import { SkeletonRows } from "@/components/ui/skeleton";
import { toast } from "@/stores/toast-store";
import { cn } from "@/lib/cn";
import { formatCents, formatDate, formatNumber } from "@/lib/format";

/** Opens a printable HTML receipt for the invoice in a new tab. */
function downloadInvoice(invoice: Invoice, workspaceName: string) {
  const rows = invoice.line_items
    .map(
      (li) =>
        `<tr><td style="padding:8px 0;border-bottom:1px solid #eee;">${li.description}</td><td style="padding:8px 0;border-bottom:1px solid #eee;text-align:right;">${formatCents(li.amount_cents, invoice.currency)}</td></tr>`,
    )
    .join("");

  const html = `<!doctype html><html><head><meta charset="utf-8"><title>Invoice ${invoice.number}</title></head>
<body style="font-family:-apple-system,Segoe UI,sans-serif;max-width:640px;margin:48px auto;color:#111;">
  <h1 style="font-size:20px;">Mokaid · Invoice ${invoice.number}</h1>
  <p style="color:#555;font-size:13px;">Workspace: ${workspaceName}<br/>
  Issued: ${invoice.issued_at ? new Date(invoice.issued_at).toLocaleDateString() : "N/A"}<br/>
  Status: ${invoice.status.toUpperCase()}</p>
  <table style="width:100%;border-collapse:collapse;font-size:14px;margin-top:24px;">
    <thead><tr><th style="text-align:left;padding:8px 0;border-bottom:2px solid #111;">Description</th><th style="text-align:right;padding:8px 0;border-bottom:2px solid #111;">Amount</th></tr></thead>
    <tbody>${rows}</tbody>
    <tfoot><tr><td style="padding:12px 0;font-weight:bold;">Total</td><td style="padding:12px 0;text-align:right;font-weight:bold;">${formatCents(invoice.amount_cents, invoice.currency)}</td></tr></tfoot>
  </table>
  <script>window.print()</script>
</body></html>`;

  const win = window.open("", "_blank", "noopener");
  if (win) {
    win.document.write(html);
    win.document.close();
  }
}

export function BillingPage() {
  const { data: overviewData, isLoading } = useBillingOverview();
  const { data: invoicesData } = useInvoices();
  const { data: plansData } = useBillingPlans();
  const { data: packsData } = useCreditPacks();
  const planCheckout = usePlanCheckout();
  const creditsCheckout = useCreditsCheckout();
  const autoRecharge = useUpdateAutoRecharge();
  const queryClient = useQueryClient();
  const [showManagePlan, setShowManagePlan] = useState(false);
  const [showPaymentSuccess, setShowPaymentSuccess] = useState(false);
  const [billingCycle, setBillingCycle] = useState<BillingCycle>("monthly");

  // Back from the PayMe hosted page: refresh billing and celebrate.
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get("payment") === "done") {
      queryClient.invalidateQueries({ queryKey: ["billing"] });
      setShowPaymentSuccess(true);
      window.history.replaceState({}, "", window.location.pathname);
    }
  }, [queryClient]);

  if (isLoading || !overviewData) {
    return (
      <div className="space-y-5">
        <h1 className="text-xl font-bold text-text">Billing</h1>
        <SkeletonRows rows={5} />
      </div>
    );
  }

  const { subscription, daily_usage, credits, credit_transactions } = overviewData.data;
  const invoices = invoicesData?.data ?? [];
  const plan = subscription?.plan;

  const dailyAiUsage = daily_usage
    .filter((d) => d.event_type === "ai_request")
    .map((d) => ({
      day: new Date(d.day).toLocaleDateString("en-US", { month: "short", day: "numeric" }),
      actions: Number(d.total),
    }));

  const buyPlan = (planKey: string) => {
    if (planKey === "enterprise") {
      window.location.href =
        "mailto:sales@mokaid.com?subject=Mokaid%20Enterprise&body=Tell%20us%20about%20your%20team%20size%20and%20needs.";
      return;
    }
    planCheckout.mutate(
      { plan_key: planKey, billing_cycle: billingCycle },
      {
        onSuccess: (result) => {
          if (result.data.activated) {
            setShowManagePlan(false);
            toast({
              tone: "success",
              title: "Plan updated",
              description: "Your new plan is active.",
            });
          }
        },
      },
    );
  };

  const isPastDue = subscription?.status === "past_due";

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-bold text-text">Billing</h1>
        <p className="text-xs text-text-muted">Plan, AI credits, usage and invoices</p>
      </div>

      {/* Dunning banner: a renewal charge failed — let the user fix it now. */}
      {isPastDue && (
        <div className="flex items-center justify-between gap-3 rounded-xl border border-warning/40 bg-warning/10 px-4 py-3">
          <div className="flex items-start gap-2.5">
            <AlertTriangle size={16} className="mt-0.5 shrink-0 text-warning" />
            <div>
              <p className="text-xs font-semibold text-text">
                We couldn't renew your {plan?.name ?? ""} plan
              </p>
              <p className="text-[11px] text-text-muted">
                Your card was declined. Pay now to keep your AI employees working — after 3
                failed attempts your workspace moves to the Free plan.
              </p>
            </div>
          </div>
          <Button
            size="sm"
            loading={planCheckout.isPending}
            onClick={() => plan && buyPlan(plan.key)}
          >
            Pay now
          </Button>
        </div>
      )}

      <div className="grid gap-5 xl:grid-cols-3">
        <Card className="xl:col-span-1">
          <CardHeader>
            <CardTitle>Current Plan</CardTitle>
            <Badge tone={isPastDue ? "warning" : "success"} dot>
              {subscription?.status ?? "free"}
            </Badge>
          </CardHeader>
          <CardBody className="space-y-4">
            <div>
              <div className="flex items-baseline gap-2">
                <span className="text-2xl font-bold text-text">{plan?.name ?? "Free"}</span>
              </div>
              <p className="mt-0.5 text-xs text-text-muted">
                {plan && plan.price_cents_monthly > 0
                  ? subscription?.billing_cycle === "yearly"
                    ? `${formatCents(plan.price_cents_yearly)} / year`
                    : `${formatCents(plan.price_cents_monthly)} / month`
                  : plan?.key === "enterprise"
                    ? "Custom contract"
                    : "Free forever"}
              </p>
            </div>

            {plan && (
              <ul className="space-y-1.5">
                {plan.features.map((feature) => (
                  <li key={feature} className="flex items-center gap-2 text-xs text-text-secondary">
                    <Sparkles size={11} className="shrink-0 text-primary-light" />
                    {feature}
                  </li>
                ))}
              </ul>
            )}

            <div className="space-y-1.5 border-t border-border pt-3 text-xs">
              <div className="flex justify-between">
                <span className="text-text-muted">Billing period</span>
                <span className="text-text">
                  {formatDate(subscription?.current_period_start)} –{" "}
                  {formatDate(subscription?.current_period_end)}
                </span>
              </div>
              {subscription?.payment_method?.last4 && (
                <div className="flex items-center justify-between">
                  <span className="text-text-muted">Payment method</span>
                  <span className="flex items-center gap-1.5 text-text">
                    <CreditCard size={13} />
                    {subscription.payment_method.brand?.toUpperCase()} ····{" "}
                    {subscription.payment_method.last4}
                  </span>
                </div>
              )}
            </div>

            <Button
              variant="secondary"
              size="sm"
              className="w-full"
              onClick={() => setShowManagePlan(true)}
            >
              Manage Plan
            </Button>
          </CardBody>
        </Card>

        <Card className="xl:col-span-2">
          <CardHeader>
            <CardTitle>AI Credits</CardTitle>
            <span
              className={cn(
                "flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-semibold",
                credits.spendable < 0
                  ? "bg-danger-muted text-danger"
                  : "bg-primary-muted text-primary-light",
              )}
            >
              <Coins size={12} />
              {credits.unlimited ? "Unlimited" : `${formatNumber(credits.spendable)} credits`}
            </span>
          </CardHeader>
          <CardBody className="space-y-4">
            {credits.unlimited ? (
              <p className="text-sm text-text-secondary">
                Your plan includes unlimited AI credits — your team can work without limits.
              </p>
            ) : (
              <>
                {/* Monthly plan pool */}
                <div>
                  <div className="mb-1 flex justify-between text-xs">
                    <span className="font-medium text-text">Monthly credits (plan)</span>
                    <span className="text-text-muted">
                      {formatNumber(credits.included_remaining)} /{" "}
                      {formatNumber(credits.monthly_credits)}
                    </span>
                  </div>
                  <ProgressBar
                    value={
                      credits.monthly_credits > 0
                        ? Math.max(
                            0,
                            (credits.included_remaining / credits.monthly_credits) * 100,
                          )
                        : 0
                    }
                    tone={
                      credits.included_remaining <= 0
                        ? "danger"
                        : credits.included_remaining / Math.max(credits.monthly_credits, 1) < 0.2
                          ? "warning"
                          : "primary"
                    }
                  />
                  <p className="mt-1 text-[10px] text-text-muted">
                    Resets on {formatDate(subscription?.current_period_end)}
                  </p>
                </div>

                {/* Purchased top-up balance */}
                <div className="flex items-center justify-between rounded-lg border border-border bg-surface-raised px-3 py-2.5">
                  <span className="text-xs font-medium text-text">Top-up balance (never expires)</span>
                  <span
                    className={cn(
                      "text-sm font-bold",
                      credits.balance < 0 ? "text-danger" : "text-text",
                    )}
                  >
                    {formatNumber(credits.balance)}
                  </span>
                </div>

                {credits.balance < 0 && (
                  <p className="rounded-lg bg-danger-muted px-3 py-2 text-[11px] text-danger">
                    You're in credit debt from a task that overran. Your next credit purchase
                    settles it automatically before topping up.
                  </p>
                )}
              </>
            )}

            <div className="h-40 pt-1">
              <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                AI activity, last 30 days
              </p>
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={dailyAiUsage}>
                  <CartesianGrid stroke={colors.border} strokeDasharray="3 3" vertical={false} />
                  <XAxis dataKey="day" stroke={colors.textMuted} fontSize={10} tickLine={false} interval={4} />
                  <YAxis stroke={colors.textMuted} fontSize={10} tickLine={false} axisLine={false} />
                  <Tooltip
                    contentStyle={{
                      backgroundColor: colors.surfaceOverlay,
                      border: `1px solid ${colors.border}`,
                      borderRadius: 8,
                      fontSize: 12,
                    }}
                    cursor={{ fill: "rgba(124,92,255,0.06)" }}
                  />
                  <Bar dataKey="actions" fill={colors.primary} radius={[3, 3, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </div>
          </CardBody>
        </Card>
      </div>

      {/* AI credit packs — top up beyond the plan's monthly quota. */}
      <Card>
        <CardHeader>
          <CardTitle>AI Credits</CardTitle>
          <p className="text-[11px] text-text-muted">
            Keep your team working past your monthly quota — credits never expire.
          </p>
        </CardHeader>
        <CardBody>
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {(packsData?.data ?? []).map((pack) => (
              <div
                key={pack.key}
                className="flex flex-col items-center rounded-lg border border-border p-4 text-center transition-colors hover:border-primary/50"
              >
                <Coins size={18} className="text-primary-light" />
                <p className="mt-2 text-lg font-bold text-text">{formatNumber(pack.credits)}</p>
                <p className="text-[11px] text-text-muted">AI credits</p>
                <Button
                  size="sm"
                  variant="secondary"
                  className="mt-3 w-full"
                  loading={
                    creditsCheckout.isPending && creditsCheckout.variables?.pack_key === pack.key
                  }
                  onClick={() =>
                    creditsCheckout.mutate(
                      { pack_key: pack.key },
                      {
                        onSuccess: (result) => {
                          if (result.data.activated) {
                            toast({
                              tone: "success",
                              title: "Credits added",
                              description: `${formatNumber(result.data.credits ?? 0)} AI credits are now available.`,
                            });
                          }
                        },
                      },
                    )
                  }
                >
                  {formatCents(pack.price_cents)}
                </Button>
              </div>
            ))}
          </div>

          {/* Auto-recharge toggle */}
          {!credits.unlimited && (
            <div className="mt-4 flex items-center justify-between rounded-lg border border-border bg-surface-raised px-4 py-3">
              <div className="flex items-start gap-2.5">
                <RefreshCw size={15} className="mt-0.5 text-primary-light" />
                <div>
                  <p className="text-xs font-semibold text-text">Auto-recharge</p>
                  <p className="text-[11px] text-text-muted">
                    Automatically buy the smallest pack when you run low, so your team never
                    stops mid-task.
                  </p>
                </div>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={credits.auto_recharge_enabled ?? false}
                disabled={autoRecharge.isPending}
                onClick={() =>
                  autoRecharge.mutate({
                    enabled: !credits.auto_recharge_enabled,
                    pack_key: credits.auto_recharge_pack_key ?? packsData?.data?.[0]?.key,
                    threshold: credits.auto_recharge_threshold || 100,
                  })
                }
                className={cn(
                  "relative h-5 w-9 shrink-0 rounded-full transition-colors",
                  credits.auto_recharge_enabled ? "bg-primary" : "bg-surface-overlay",
                )}
              >
                <span
                  className={cn(
                    "absolute top-0.5 h-4 w-4 rounded-full bg-white transition-transform",
                    credits.auto_recharge_enabled ? "translate-x-4" : "translate-x-0.5",
                  )}
                />
              </button>
            </div>
          )}
        </CardBody>
      </Card>

      {/* Live consumption history */}
      {credit_transactions.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle>Recent AI usage</CardTitle>
            <p className="text-[11px] text-text-muted">Live — updates as your team works</p>
          </CardHeader>
          <CardBody className="px-0 pb-2">
            <table className="w-full text-left text-xs">
              <tbody>
                {credit_transactions.slice(0, 12).map((txn) => (
                  <tr
                    key={txn.id}
                    className="border-b border-border/50 last:border-0 hover:bg-surface-hover"
                  >
                    <td className="px-5 py-2.5 text-text-secondary">{formatDate(txn.inserted_at)}</td>
                    <td className="px-3 py-2.5 text-text">
                      {txn.description ??
                        (txn.kind === "spend" ? "AI task" : txn.kind.replace("_", " "))}
                    </td>
                    <td
                      className={cn(
                        "px-5 py-2.5 text-right font-semibold",
                        txn.amount < 0 ? "text-text-muted" : "text-success",
                      )}
                    >
                      {txn.amount > 0 ? "+" : ""}
                      {formatNumber(txn.amount)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </CardBody>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle>Invoices</CardTitle>
        </CardHeader>
        <CardBody className="px-0 pb-2">
          <table className="w-full text-left text-xs">
            <thead>
              <tr className="border-b border-border text-[11px] uppercase tracking-wide text-text-muted">
                <th className="px-5 py-2 font-medium">Invoice</th>
                <th className="px-3 py-2 font-medium">Date</th>
                <th className="px-3 py-2 font-medium">Amount</th>
                <th className="px-3 py-2 font-medium">Status</th>
                <th className="px-5 py-2 text-right font-medium">Download</th>
              </tr>
            </thead>
            <tbody>
              {invoices.map((invoice) => (
                <tr key={invoice.id} className="border-b border-border/50 last:border-0 hover:bg-surface-hover">
                  <td className="px-5 py-3 font-medium text-text">{invoice.number}</td>
                  <td className="px-3 py-3 text-text-secondary">{formatDate(invoice.issued_at)}</td>
                  <td className="px-3 py-3 text-text">{formatCents(invoice.amount_cents, invoice.currency)}</td>
                  <td className="px-3 py-3">
                    <Badge tone={invoice.status === "paid" ? "success" : "warning"}>
                      {invoice.status}
                    </Badge>
                  </td>
                  <td className="px-5 py-3 text-right">
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label={`Download ${invoice.number}`}
                      onClick={() => downloadInvoice(invoice, "Mokaid Workspace")}
                    >
                      <Download size={14} />
                    </Button>
                  </td>
                </tr>
              ))}
              {invoices.length === 0 && (
                <tr>
                  <td colSpan={5} className="px-5 py-8 text-center text-text-muted">
                    No invoices yet
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </CardBody>
      </Card>

      <Dialog
        open={showManagePlan}
        onOpenChange={setShowManagePlan}
        title="Choose your plan"
        description="Hire more AI employees as your team grows — upgrade or downgrade anytime."
        className="w-[880px] max-w-[95vw]"
      >
        <div className="space-y-4">
          <div className="flex justify-center">
            <BillingCycleToggle cycle={billingCycle} onChange={setBillingCycle} />
          </div>
          <PlanPicker
            plans={plansData?.data ?? []}
            currentKey={plan?.key}
            pendingKey={planCheckout.isPending ? planCheckout.variables?.plan_key : undefined}
            onChoose={buyPlan}
            cycle={billingCycle}
            compact
          />
        </div>
      </Dialog>

      {/* Celebration modal shown when the user comes back from a paid checkout. */}
      <Dialog
        open={showPaymentSuccess}
        onOpenChange={setShowPaymentSuccess}
        title=""
        className="w-[420px] max-w-[92vw]"
      >
        <div className="flex flex-col items-center gap-3 py-4 text-center">
          <span className="relative flex h-16 w-16 items-center justify-center">
            <span className="absolute inset-0 animate-ping rounded-full bg-success/20" />
            <span className="relative flex h-14 w-14 items-center justify-center rounded-full bg-success/15">
              <CheckCircle2 size={30} className="text-success" />
            </span>
          </span>
          <div>
            <h2 className="text-lg font-bold text-text">Payment successful</h2>
            <p className="mt-1 text-xs leading-relaxed text-text-muted">
              Thank you! Your plan or credits are being activated — this usually takes a few
              seconds. Your AI team is ready to work.
            </p>
          </div>
          <Button size="sm" className="mt-1 w-40" onClick={() => setShowPaymentSuccess(false)}>
            Let's go
          </Button>
        </div>
      </Dialog>
    </div>
  );
}
