import { useState } from "react";
import { Check, CreditCard, Download, Sparkles } from "lucide-react";
import {
  Bar,
  BarChart,
  CartesianGrid,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { colors } from "@mokaid/design-tokens";
import {
  useBillingOverview,
  useBillingPlans,
  useChangePlan,
  useInvoices,
} from "@/api/hooks";
import type { Invoice } from "@/api/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { Dialog } from "@/components/ui/dialog";
import { ProgressBar } from "@/components/ui/progress-bar";
import { SkeletonRows } from "@/components/ui/skeleton";
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
  <h1 style="font-size:20px;">Mokaid — Invoice ${invoice.number}</h1>
  <p style="color:#555;font-size:13px;">Workspace: ${workspaceName}<br/>
  Issued: ${invoice.issued_at ? new Date(invoice.issued_at).toLocaleDateString() : "—"}<br/>
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

const usageLabels: Record<string, { label: string; limitKey: string }> = {
  ai_request: { label: "AI Requests", limitKey: "ai_requests_monthly" },
  api_call: { label: "API Calls", limitKey: "api_calls_monthly" },
  automation_run: { label: "Automations", limitKey: "automations_monthly" },
  task_executed: { label: "Tasks Executed", limitKey: "tasks_monthly" },
  storage_used: { label: "Storage (MB)", limitKey: "storage_gb" },
};

export function BillingPage() {
  const { data: overviewData, isLoading } = useBillingOverview();
  const { data: invoicesData } = useInvoices();
  const { data: plansData } = useBillingPlans();
  const changePlan = useChangePlan();
  const [showManagePlan, setShowManagePlan] = useState(false);

  if (isLoading || !overviewData) {
    return (
      <div className="space-y-5">
        <h1 className="text-xl font-bold text-text">Billing</h1>
        <SkeletonRows rows={5} />
      </div>
    );
  }

  const { subscription, usage, daily_usage } = overviewData.data;
  const invoices = invoicesData?.data ?? [];
  const plan = subscription?.plan;

  const dailyAiUsage = daily_usage
    .filter((d) => d.event_type === "ai_request")
    .map((d) => ({
      day: new Date(d.day).toLocaleDateString("en-US", { month: "short", day: "numeric" }),
      requests: Number(d.total),
    }));

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-xl font-bold text-text">Billing</h1>
        <p className="text-xs text-text-muted">Plan, usage and invoices</p>
      </div>

      <div className="grid gap-5 xl:grid-cols-3">
        <Card className="xl:col-span-1">
          <CardHeader>
            <CardTitle>Current Plan</CardTitle>
            <Badge tone="success" dot>
              {subscription?.status ?? "none"}
            </Badge>
          </CardHeader>
          <CardBody className="space-y-4">
            <div>
              <div className="flex items-baseline gap-2">
                <span className="text-2xl font-bold text-text">{plan?.name ?? "Free"}</span>
              </div>
              <p className="mt-0.5 text-xs text-text-muted">
                {plan
                  ? subscription?.billing_cycle === "yearly"
                    ? `${formatCents(plan.price_cents_yearly)} / year`
                    : `${formatCents(plan.price_cents_monthly)} / month`
                  : "No subscription"}
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
              <div className="flex items-center justify-between">
                <span className="text-text-muted">Payment method</span>
                <span className="flex items-center gap-1.5 text-text">
                  <CreditCard size={13} />
                  {subscription?.payment_method?.brand?.toUpperCase()} ····{" "}
                  {subscription?.payment_method?.last4}
                </span>
              </div>
            </div>

            <Button variant="secondary" size="sm" className="w-full" onClick={() => setShowManagePlan(true)}>
              Manage Plan
            </Button>
          </CardBody>
        </Card>

        <Card className="xl:col-span-2">
          <CardHeader>
            <CardTitle>Usage This Period</CardTitle>
          </CardHeader>
          <CardBody className="space-y-4">
            {usage
              .filter((u) => usageLabels[u.event_type])
              .map((u) => {
                const config = usageLabels[u.event_type];
                const quantity = Number(u.total_quantity);
                const limit = plan?.limits?.[config.limitKey];
                const percent = limit ? Math.min(100, (quantity / limit) * 100) : 0;

                return (
                  <div key={u.event_type}>
                    <div className="mb-1 flex justify-between text-xs">
                      <span className="font-medium text-text">{config.label}</span>
                      <span className="text-text-muted">
                        {formatNumber(Math.round(quantity))}
                        {limit ? ` / ${formatNumber(limit)}` : ""}
                      </span>
                    </div>
                    <ProgressBar
                      value={percent}
                      tone={percent > 90 ? "danger" : percent > 70 ? "warning" : "primary"}
                    />
                  </div>
                );
              })}

            <div className="h-44 pt-2">
              <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                AI requests, last 30 days
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
                  <Bar dataKey="requests" fill={colors.primary} radius={[3, 3, 0, 0]} />
                </BarChart>
              </ResponsiveContainer>
            </div>
          </CardBody>
        </Card>
      </div>

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
        title="Manage Plan"
        description="Choose the plan that fits your team."
        className="w-[640px]"
      >
        <div className="grid gap-3 sm:grid-cols-3">
          {(plansData?.data ?? []).map((p) => {
            const isCurrent = p.key === plan?.key;
            return (
              <div
                key={p.key}
                className={cn(
                  "flex flex-col rounded-lg border p-4",
                  isCurrent ? "border-primary/50 bg-primary-muted/20" : "border-border",
                )}
              >
                <p className="text-sm font-bold text-text">{p.name}</p>
                <p className="mt-1 text-lg font-bold text-text">
                  {formatCents(p.price_cents_monthly)}
                  <span className="text-[11px] font-normal text-text-muted"> /mo</span>
                </p>
                <ul className="mt-3 flex-1 space-y-1.5">
                  {p.features.slice(0, 4).map((f) => (
                    <li key={f} className="flex items-start gap-1.5 text-[11px] text-text-secondary">
                      <Check size={11} className="mt-0.5 shrink-0 text-success" />
                      {f}
                    </li>
                  ))}
                </ul>
                <Button
                  size="sm"
                  variant={isCurrent ? "secondary" : "primary"}
                  disabled={isCurrent}
                  loading={changePlan.isPending && changePlan.variables?.plan_key === p.key}
                  className="mt-4 w-full"
                  onClick={() =>
                    changePlan.mutate(
                      { plan_key: p.key },
                      { onSuccess: () => setShowManagePlan(false) },
                    )
                  }
                >
                  {isCurrent ? "Current plan" : "Switch"}
                </Button>
              </div>
            );
          })}
        </div>
      </Dialog>
    </div>
  );
}
