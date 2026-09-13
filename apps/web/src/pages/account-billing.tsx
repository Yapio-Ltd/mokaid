import { useEffect, useState } from "react";
import { useRouterState } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import {
  useBillingOverview,
  useBillingPlans,
  useBillingPortal,
  useCreditPacks,
  useCreditsCheckout,
  useInvoices,
  usePlanCheckout,
  useUpdateAutoRecharge,
} from "@/api/hooks";
import type { Invoice } from "@/api/types";
import {
  BillingCycleToggle,
  PlanPicker,
  type BillingCycle,
} from "@/components/billing/plan-picker";
import { redirectToCheckout } from "@/components/billing/checkout-dialog";
import { Button } from "@/components/ui/button";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/ui/page-header";
import { formatCents, formatDate, formatNumber } from "@/lib/format";
import { useAuthStore } from "@/stores/auth-store";

const titles: Record<string, string> = {
  billing: "Billing",
  plans: "Plans",
  usage: "Usage",
  spending: "Spending & credits",
  invoices: "Invoices",
};

function escapeHtml(value: string): string {
  return value.replace(
    /[&<>"']/g,
    (character) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character] ??
      character,
  );
}

/** A printable copy, not a fabricated PDF or a privileged HTML preview. */
export function invoiceDocument(invoice: Invoice, workspace: string): string {
  const rows = invoice.line_items
    .map(
      (item) =>
        `<tr><td>${escapeHtml(item.description)}</td><td>${escapeHtml(formatCents(item.amount_cents, invoice.currency))}</td></tr>`,
    )
    .join("");
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><title>Invoice ${escapeHtml(invoice.number)}</title><style>body{font:16px system-ui;margin:3rem auto;max-width:50rem;padding:1rem}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:.7rem;border-bottom:1px solid #ccc}</style></head><body><h1>Mokaid · Invoice ${escapeHtml(invoice.number)}</h1><p>Workspace: ${escapeHtml(workspace)}</p><p>Issued: ${escapeHtml(formatDate(invoice.issued_at))} · ${escapeHtml(invoice.status)}</p><table><thead><tr><th>Description</th><th>Amount</th></tr></thead><tbody>${rows}</tbody></table><p>Total: ${escapeHtml(formatCents(invoice.amount_cents, invoice.currency))}</p></body></html>`;
}

function downloadInvoice(invoice: Invoice, workspace: string): void {
  const objectUrl = URL.createObjectURL(
    new Blob([invoiceDocument(invoice, workspace)], { type: "text/html;charset=utf-8" }),
  );
  const link = document.createElement("a");
  link.href = objectUrl;
  link.download = `Mokaid-invoice-${invoice.number.replace(/[^a-zA-Z0-9_-]/g, "_")}.html`;
  link.click();
  // Give the browser time to consume the object URL before releasing it.
  window.setTimeout(() => URL.revokeObjectURL(objectUrl), 1000);
}

/** Real billing endpoints only; never fetches analytics/work content or assets. */
export function AccountBillingPage() {
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const section = pathname.split("/")[2] ?? "billing";
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const workspaces = useAuthStore((state) => state.workspaces);
  const overview = useBillingOverview();
  const plans = useBillingPlans();
  const packs = useCreditPacks();
  const invoices = useInvoices();
  const planCheckout = usePlanCheckout();
  const creditsCheckout = useCreditsCheckout();
  const portal = useBillingPortal();
  const autoRecharge = useUpdateAutoRecharge();
  const queryClient = useQueryClient();
  const [cycle, setCycle] = useState<BillingCycle>("monthly");
  const [notice, setNotice] = useState<string | null>(null);
  const [failure, setFailure] = useState<string | null>(null);

  useEffect(() => {
    setFailure(null);
    setNotice(null);
  }, [workspaceId]);

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const checkout = params.get("checkout");
    const paid = checkout === "success" || params.get("payment") === "done";
    if (!paid && checkout !== "canceled") return;
    setNotice(
      paid
        ? "Payment returned successfully. Your balance will update after payment confirmation."
        : "Checkout canceled. Your card was not charged.",
    );
    void queryClient.invalidateQueries({ queryKey: ["billing"] });
    const timers = paid
      ? [2500, 6000].map((delay) =>
          window.setTimeout(
            () => void queryClient.invalidateQueries({ queryKey: ["billing"] }),
            delay,
          ),
        )
      : [];
    // Remove only payment markers, retaining any other legitimate navigation state.
    params.delete("checkout");
    params.delete("payment");
    window.history.replaceState(
      window.history.state,
      "",
      `${window.location.pathname}${params.size ? `?${params}` : ""}`,
    );
    return () => timers.forEach(window.clearTimeout);
  }, [queryClient]);

  const onError = (error: unknown) =>
    setFailure(
      error instanceof Error ? error.message : "The billing request failed. Please try again.",
    );

  if (!workspaceId)
    return (
      <div className="space-y-3">
        <PageHeader title={titles[section] ?? "Billing"} />
        <p className="text-sm text-text-muted">
          No workspace is available for billing. You can still manage your profile and security.
        </p>
      </div>
    );
  if (overview.isPending)
    return (
      <p role="status" className="text-sm text-text-muted">
        Loading billing…
      </p>
    );
  if (overview.error || !overview.data)
    return (
      <div role="alert" className="space-y-3">
        <p>
          {overview.error instanceof Error
            ? overview.error.message
            : "Billing could not be loaded."}
        </p>
        <Button onClick={() => void overview.refetch()}>Try again</Button>
      </div>
    );

  const { subscription, credits, daily_usage, usage, credit_transactions } = overview.data.data;
  const plan = subscription?.plan;
  const workspace = workspaces.find((item) => item.id === workspaceId)?.name ?? "";

  return (
    <div className="space-y-6">
      <PageHeader
        title={titles[section] ?? "Billing"}
        subtitle={`Manage subscriptions and payments for ${workspace}.`}
      />
      {notice && (
        <p
          role="status"
          className="rounded-lg border border-primary/30 p-3 text-sm text-text-secondary"
        >
          {notice}
        </p>
      )}
      {failure && (
        <p role="alert" className="rounded-lg border border-danger/30 p-3 text-sm text-danger">
          {failure}
        </p>
      )}
      {subscription?.status === "past_due" && (
        <p role="alert" className="rounded-lg border border-warning/40 p-3 text-sm text-warning">
          Your subscription payment is past due. Update your payment method using Manage billing.
        </p>
      )}

      {section === "billing" && (
        <div className="grid gap-5 lg:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle>Current plan</CardTitle>
            </CardHeader>
            <CardBody className="space-y-4">
              <p className="text-2xl font-semibold">{plan?.name ?? "Free"}</p>
              <p className="text-xs text-text-muted">
                {subscription?.status ?? "free"} · {subscription?.billing_cycle ?? "monthly"}
              </p>
              <p className="text-sm">
                Billing period: {formatDate(subscription?.current_period_start)} –{" "}
                {formatDate(subscription?.current_period_end)}
              </p>
              {subscription?.payment_method?.last4 && (
                <p className="text-sm">
                  {subscription.payment_method.brand} ···· {subscription.payment_method.last4}
                </p>
              )}
              <Button
                loading={portal.isPending}
                onClick={() => {
                  setFailure(null);
                  portal.mutate(undefined, { onError });
                }}
              >
                Manage billing
              </Button>
              <p className="text-xs text-text-muted">
                Opens the secure Stripe portal to manage payment methods, subscriptions and
                receipts.
              </p>
            </CardBody>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle>AI credits</CardTitle>
            </CardHeader>
            <CardBody className="space-y-3">
              <p className="text-2xl font-semibold">
                {credits.unlimited ? "Unlimited" : formatNumber(credits.spendable)}
              </p>
              <p className="text-sm">
                Monthly credits remaining: {formatNumber(credits.included_remaining)} /{" "}
                {formatNumber(credits.monthly_credits)}
              </p>
              <p className="text-sm">Top-up balance: {formatNumber(credits.balance)}</p>
            </CardBody>
          </Card>
        </div>
      )}

      {section === "plans" && (
        <div className="space-y-5">
          {plans.error ? (
            <p role="alert">
              Plans could not be loaded.{" "}
              <button className="text-primary-light underline" onClick={() => void plans.refetch()}>
                Try again
              </button>
            </p>
          ) : plans.isPending ? (
            <p role="status">Loading plans…</p>
          ) : (
            <>
              <BillingCycleToggle cycle={cycle} onChange={setCycle} />
              <PlanPicker
                plans={plans.data?.data ?? []}
                currentKey={plan?.key}
                pendingKey={planCheckout.isPending ? planCheckout.variables?.plan_key : undefined}
                cycle={cycle}
                onChoose={(planKey) => {
                  setFailure(null);
                  planCheckout.mutate(
                    { plan_key: planKey, billing_cycle: cycle, return_path: "/account/billing" },
                    {
                      onError,
                      onSuccess: (result) => {
                        if (result.data.sale_url) redirectToCheckout(result.data.sale_url);
                        else if (result.data.activated) setNotice("Your plan has been updated.");
                      },
                    },
                  );
                }}
              />
            </>
          )}
        </div>
      )}

      {section === "usage" && (
        <div className="space-y-5">
          <Card>
            <CardHeader>
              <CardTitle>Usage this billing period</CardTitle>
            </CardHeader>
            <CardBody>
              {!usage.length ? (
                <p className="text-sm text-text-muted">No usage recorded for this period.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-left text-sm">
                    <thead>
                      <tr>
                        <th className="p-2">Event</th>
                        <th className="p-2">Quantity</th>
                        <th className="p-2">Unit</th>
                        <th className="p-2">Cost</th>
                      </tr>
                    </thead>
                    <tbody>
                      {usage.map((item) => (
                        <tr
                          key={`${item.event_type}-${item.unit}`}
                          className="border-t border-border"
                        >
                          <td className="p-2">{item.event_type}</td>
                          <td className="p-2">{formatNumber(Number(item.total_quantity))}</td>
                          <td className="p-2">{item.unit}</td>
                          <td className="p-2">{formatCents(item.total_cost_cents)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </CardBody>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle>Daily usage · last 30 days</CardTitle>
            </CardHeader>
            <CardBody>
              {!daily_usage.length ? (
                <p className="text-sm text-text-muted">No daily usage recorded.</p>
              ) : (
                <div className="max-h-96 overflow-auto">
                  <table className="w-full text-left text-sm">
                    <thead>
                      <tr>
                        <th className="p-2">Date</th>
                        <th className="p-2">Event</th>
                        <th className="p-2">Quantity</th>
                      </tr>
                    </thead>
                    <tbody>
                      {daily_usage.map((item) => (
                        <tr
                          key={`${item.day}-${item.event_type}`}
                          className="border-t border-border"
                        >
                          <td className="p-2">{formatDate(item.day)}</td>
                          <td className="p-2">{item.event_type}</td>
                          <td className="p-2">{formatNumber(Number(item.total))}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </CardBody>
          </Card>
        </div>
      )}

      {section === "spending" && (
        <div className="space-y-5">
          <Card>
            <CardHeader>
              <CardTitle>Buy credits</CardTitle>
            </CardHeader>
            <CardBody className="space-y-4">
              <p className="text-sm">
                Available:{" "}
                {credits.unlimited ? "Unlimited" : `${formatNumber(credits.spendable)} credits`}
              </p>
              {packs.error ? (
                <p role="alert">
                  Credit packs could not be loaded.{" "}
                  <button
                    className="text-primary-light underline"
                    onClick={() => void packs.refetch()}
                  >
                    Try again
                  </button>
                </p>
              ) : (
                <div className="grid gap-3 sm:grid-cols-2">
                  {packs.data?.data.map((pack) => (
                    <Button
                      key={pack.key}
                      variant="secondary"
                      disabled={creditsCheckout.isPending}
                      onClick={() => {
                        setFailure(null);
                        creditsCheckout.mutate(
                          { pack_key: pack.key, return_path: "/account/spending" },
                          {
                            onError,
                            onSuccess: (result) => {
                              if (result.data.sale_url) redirectToCheckout(result.data.sale_url);
                              else if (result.data.activated)
                                setNotice(
                                  `${formatNumber(result.data.credits ?? 0)} credits added.`,
                                );
                            },
                          },
                        );
                      }}
                    >
                      {formatNumber(pack.credits)} credits · {formatCents(pack.price_cents)}
                    </Button>
                  ))}
                </div>
              )}
              {!credits.unlimited && (
                <label className="flex items-center gap-3 text-sm">
                  <input
                    type="checkbox"
                    checked={credits.auto_recharge_enabled ?? false}
                    disabled={autoRecharge.isPending || !packs.data?.data.length}
                    onChange={(event) => {
                      setFailure(null);
                      autoRecharge.mutate(
                        {
                          enabled: event.target.checked,
                          pack_key: credits.auto_recharge_pack_key ?? packs.data?.data[0]?.key,
                          threshold: credits.auto_recharge_threshold || 100,
                        },
                        { onError },
                      );
                    }}
                  />
                  Auto-recharge when credits fall below{" "}
                  {formatNumber(credits.auto_recharge_threshold || 100)}.
                </label>
              )}
              {credits.auto_recharge_enabled && (
                <p className="text-xs text-text-muted">
                  Selected pack: {credits.auto_recharge_pack_key}. Your saved payment method will be
                  charged automatically.
                </p>
              )}
            </CardBody>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle>Recent credit transactions</CardTitle>
            </CardHeader>
            <CardBody>
              {!credit_transactions.length ? (
                <p className="text-sm text-text-muted">No credit transactions yet.</p>
              ) : (
                <div className="max-h-96 overflow-auto">
                  <table className="w-full text-left text-sm">
                    <thead>
                      <tr>
                        <th className="p-2">Date</th>
                        <th className="p-2">Description</th>
                        <th className="p-2">Credits</th>
                        <th className="p-2">Cost</th>
                        <th className="p-2">Balance</th>
                      </tr>
                    </thead>
                    <tbody>
                      {credit_transactions.map((item) => (
                        <tr key={item.id} className="border-t border-border">
                          <td className="p-2">{formatDate(item.inserted_at)}</td>
                          <td className="p-2">{item.description ?? item.kind}</td>
                          <td className="p-2">{formatNumber(item.amount)}</td>
                          <td className="p-2">{formatCents(item.cost_cents)}</td>
                          <td className="p-2">{formatNumber(item.balance_after)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </CardBody>
          </Card>
        </div>
      )}

      {section === "invoices" && (
        <Card>
          <CardHeader>
            <CardTitle>Invoices</CardTitle>
          </CardHeader>
          <CardBody>
            {invoices.error ? (
              <p role="alert">
                Invoices could not be loaded.{" "}
                <button
                  className="text-primary-light underline"
                  onClick={() => void invoices.refetch()}
                >
                  Try again
                </button>
              </p>
            ) : invoices.isPending ? (
              <p role="status">Loading invoices…</p>
            ) : !invoices.data?.data.length ? (
              <p className="text-sm text-text-muted">No invoices yet.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead>
                    <tr>
                      <th className="p-2">Invoice</th>
                      <th className="p-2">Date</th>
                      <th className="p-2">Status</th>
                      <th className="p-2">Amount</th>
                      <th className="p-2">Copy</th>
                    </tr>
                  </thead>
                  <tbody>
                    {invoices.data.data.map((invoice) => (
                      <tr key={invoice.id} className="border-t border-border">
                        <td className="p-2">{invoice.number}</td>
                        <td className="p-2">{formatDate(invoice.issued_at)}</td>
                        <td className="p-2">{invoice.status}</td>
                        <td className="p-2">
                          {formatCents(invoice.amount_cents, invoice.currency)}
                        </td>
                        <td className="p-2">
                          <Button
                            size="sm"
                            variant="ghost"
                            onClick={() => downloadInvoice(invoice, workspace)}
                          >
                            Download printable copy
                          </Button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </CardBody>
        </Card>
      )}
    </div>
  );
}
