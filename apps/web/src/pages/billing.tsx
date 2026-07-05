import { CreditCard, Download, Sparkles } from "lucide-react";
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
import { useBillingOverview, useInvoices } from "@/api/hooks";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { ProgressBar } from "@/components/ui/progress-bar";
import { SkeletonRows } from "@/components/ui/skeleton";
import { formatCents, formatDate, formatNumber } from "@/lib/format";

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

            <Button variant="secondary" size="sm" className="w-full">
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
                    <Button variant="ghost" size="icon" aria-label={`Download ${invoice.number}`}>
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
    </div>
  );
}
