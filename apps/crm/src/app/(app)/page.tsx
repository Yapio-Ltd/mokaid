"use client";

import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { apiRequest, formatCents } from "@/lib/api";
import type { Metrics, MetricsTimeseries } from "@/lib/types";
import { Card, Kpi, Loading, PageHeader, Select } from "@/components/ui";
import { SimpleAreaChart, SimpleBarChart, SimpleLineChart, dayLabel } from "@/components/charts";

export default function DashboardPage() {
  const [days, setDays] = useState("30");

  const { data, isLoading, error } = useQuery({
    queryKey: ["metrics"],
    queryFn: () => apiRequest<{ data: Metrics }>("/api/admin/metrics"),
  });

  const series = useQuery({
    queryKey: ["metrics-ts", days],
    queryFn: () =>
      apiRequest<{ data: MetricsTimeseries }>(`/api/admin/metrics/timeseries?days=${days}`),
  });

  const m = data?.data;
  const ts = series.data?.data;

  const usageChart = useMemo(() => {
    if (!ts?.usage) return [];
    return ts.usage.map((r) => ({
      label: dayLabel(r.day as unknown as string),
      cost: Number(r.cost_cents || 0) / 100,
      events: r.events,
    }));
  }, [ts]);

  const usersChart = useMemo(() => {
    if (!ts?.new_users) return [];
    return ts.new_users.map((r) => ({
      label: dayLabel(r.day as unknown as string),
      count: r.count,
    }));
  }, [ts]);

  const providerChart = useMemo(() => {
    if (!ts?.provider_costs) return [];
    const byDay = new Map<string, Record<string, number | string>>();
    for (const row of ts.provider_costs) {
      const label = dayLabel(row.day as unknown as string);
      const cur = byDay.get(label) || { label };
      cur[row.provider] = (Number(cur[row.provider]) || 0) + Number(row.amount_cents || 0) / 100;
      byDay.set(label, cur);
    }
    return Array.from(byDay.values());
  }, [ts]);

  const creditsChart = useMemo(() => {
    if (!ts?.credits_spend) return [];
    return ts.credits_spend.map((r) => ({
      label: dayLabel(r.day as unknown as string),
      credits: r.credits,
      cost: Number(r.cost_cents || 0) / 100,
    }));
  }, [ts]);

  return (
    <div>
      <PageHeader
        title="Vue d'ensemble"
        description="KPI plateforme, coûts fournisseurs, croissance et alertes."
        actions={
          <Select value={days} onChange={(e) => setDays(e.target.value)} className="w-32">
            <option value="7">7 jours</option>
            <option value="30">30 jours</option>
            <option value="90">90 jours</option>
          </Select>
        }
      />
      {isLoading ? <Loading /> : null}
      {error ? <p className="text-sm text-danger">{(error as Error).message}</p> : null}

      {m ? (
        <>
          {(m.subscriptions_past_due > 0 ||
            (m.invoices_pending || 0) > 0 ||
            (m.deletions_pending || 0) > 0) && (
            <Card className="mb-4 border border-warn/30 bg-warn/5 p-4 text-sm text-warn">
              Alertes : {m.subscriptions_past_due} abos past due · {m.invoices_pending} factures
              pending · {m.deletions_pending || 0} suppressions planifiées
            </Card>
          )}

          <div className="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <Kpi label="Utilisateurs" value={m.users_total} hint={`${m.users_active} actifs`} />
            <Kpi label="Nouveaux (30j)" value={m.new_users_30d} />
            <Kpi label="Bannis / suspendus" value={m.users_banned ?? 0} />
            <Kpi label="Workspaces" value={m.workspaces_total} />
            <Kpi label="MRR" value={formatCents(m.mrr_cents)} />
            <Kpi label="ARR" value={formatCents(m.arr_cents || m.mrr_cents * 12)} />
            <Kpi label="ARPU" value={formatCents(m.arpu_cents || 0)} />
            <Kpi label="Abos actifs" value={m.subscriptions_active} />
            <Kpi
              label="Coût OpenAI (MTD)"
              value={formatCents(m.openai_cost_mtd_cents || 0)}
            />
            <Kpi
              label="Coût Anthropic (MTD)"
              value={formatCents(m.anthropic_cost_mtd_cents || 0)}
            />
            <Kpi label="Coût AWS (MTD)" value={formatCents(m.aws_cost_mtd_cents || 0)} />
            <Kpi
              label="Marge brute (MRR − providers)"
              value={formatCents(m.gross_margin_cents || 0)}
              hint={`IA interne estimée ${formatCents(m.internal_ai_cost_mtd_cents || 0)}`}
            />
            <Kpi label="Crédits dépensés (30j)" value={m.credits_spend_30d ?? 0} />
            <Kpi label="Solde crédits total" value={m.credits_balance_total ?? 0} />
            <Kpi label="Past due" value={m.subscriptions_past_due} />
            <Kpi label="Factures pending" value={m.invoices_pending} />
          </div>

          <div className="grid gap-4 lg:grid-cols-2">
            <Card className="p-4">
              <h3 className="mb-2 text-sm font-medium text-muted">Nouveaux utilisateurs</h3>
              <SimpleBarChart
                data={usersChart}
                bars={[{ key: "count", name: "Nouveaux", color: "#3d8bfd" }]}
              />
            </Card>
            <Card className="p-4">
              <h3 className="mb-2 text-sm font-medium text-muted">
                Coût IA interne estimé (USD)
              </h3>
              <SimpleAreaChart
                data={usageChart}
                areas={[{ key: "cost", name: "Coût $", color: "#f5a524" }]}
              />
            </Card>
            <Card className="p-4">
              <h3 className="mb-2 text-sm font-medium text-muted">
                Coûts fournisseurs facturés (USD)
              </h3>
              <SimpleLineChart
                data={providerChart}
                lines={[
                  { key: "openai", name: "OpenAI", color: "#3ecf8e" },
                  { key: "anthropic", name: "Anthropic", color: "#a78bfa" },
                  { key: "aws", name: "AWS", color: "#f5a524" },
                ]}
              />
            </Card>
            <Card className="p-4">
              <h3 className="mb-2 text-sm font-medium text-muted">Crédits consommés</h3>
              <SimpleBarChart
                data={creditsChart}
                bars={[{ key: "credits", name: "Crédits", color: "#22d3ee" }]}
              />
            </Card>
          </div>
        </>
      ) : null}
    </div>
  );
}
