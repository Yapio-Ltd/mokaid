"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { apiRequest, formatCents, formatDate } from "@/lib/api";
import type { CostListResponse, CostSummary } from "@/lib/types";
import {
  Button,
  Card,
  Empty,
  Kpi,
  Loading,
  PageHeader,
  Select,
  Table,
  Td,
  Th,
} from "@/components/ui";
import { SimpleBarChart, SimpleLineChart, dayLabel } from "@/components/charts";

export default function CostsPage() {
  const [days, setDays] = useState("30");
  const [provider, setProvider] = useState("all");
  const qc = useQueryClient();

  const summary = useQuery({
    queryKey: ["cost-summary", days],
    queryFn: () =>
      apiRequest<{ data: CostSummary }>(`/api/admin/costs/summary?days=${days}`),
  });

  const list = useQuery({
    queryKey: ["costs", days, provider],
    queryFn: () => {
      const p = new URLSearchParams({ days });
      if (provider !== "all") p.set("provider", provider);
      return apiRequest<{ data: CostListResponse }>(`/api/admin/costs?${p}`);
    },
  });

  const sync = useMutation({
    mutationFn: () =>
      apiRequest("/api/admin/costs/sync", { method: "POST", body: { days: Number(days) } }),
    onSuccess: () => {
      setTimeout(() => {
        qc.invalidateQueries({ queryKey: ["costs"] });
        qc.invalidateQueries({ queryKey: ["cost-summary"] });
        qc.invalidateQueries({ queryKey: ["metrics"] });
      }, 2000);
    },
  });

  const s = summary.data?.data;
  const d = list.data?.data;

  const chart = useMemo(() => {
    if (!d?.snapshots) return [];
    const byDay = new Map<string, Record<string, number | string>>();
    for (const snap of d.snapshots) {
      const label = dayLabel(snap.period_start);
      const cur = byDay.get(label) || { label };
      cur[snap.provider] =
        (Number(cur[snap.provider]) || 0) + Number(snap.amount_cents || 0) / 100;
      byDay.set(label, cur);
    }
    return Array.from(byDay.values());
  }, [d]);

  const awsByService = useMemo(() => {
    if (!d?.snapshots) return [];
    return d.snapshots
      .filter((x) => x.provider === "aws")
      .reduce<Record<string, number>>((acc, snap) => {
        const service = String(snap.breakdown?.service || "Other");
        acc[service] = (acc[service] || 0) + snap.amount_cents / 100;
        return acc;
      }, {});
  }, [d]);

  const awsBars = useMemo(
    () =>
      Object.entries(awsByService)
        .sort((a, b) => b[1] - a[1])
        .slice(0, 12)
        .map(([label, amount]) => ({ label: label.slice(0, 24), amount })),
    [awsByService],
  );

  return (
    <div>
      <PageHeader
        title="Coûts plateforme"
        description="Factures OpenAI / Anthropic (Admin API) et AWS Cost Explorer, réconciliation vs usage interne."
        actions={
          <div className="flex gap-2">
            <Select value={days} onChange={(e) => setDays(e.target.value)} className="w-28">
              <option value="7">7j</option>
              <option value="30">30j</option>
              <option value="90">90j</option>
            </Select>
            <Select
              value={provider}
              onChange={(e) => setProvider(e.target.value)}
              className="w-36"
            >
              <option value="all">Tous</option>
              <option value="openai">OpenAI</option>
              <option value="anthropic">Anthropic</option>
              <option value="aws">AWS</option>
            </Select>
            <Button onClick={() => sync.mutate()} disabled={sync.isPending}>
              {sync.isPending ? "Sync…" : "Synchroniser"}
            </Button>
          </div>
        }
      />

      {summary.isLoading ? <Loading /> : null}
      {sync.isSuccess ? (
        <p className="mb-3 text-sm text-success">Jobs de sync enqueued — rafraîchissement auto.</p>
      ) : null}
      {sync.isError ? (
        <p className="mb-3 text-sm text-danger">{(sync.error as Error).message}</p>
      ) : null}

      {s ? (
        <div className="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <Kpi label="Total window" value={formatCents(s.window_total_cents)} />
          <Kpi label="OpenAI MTD" value={formatCents(s.openai_cost_mtd_cents)} />
          <Kpi label="Anthropic MTD" value={formatCents(s.anthropic_cost_mtd_cents)} />
          <Kpi label="AWS MTD" value={formatCents(s.aws_cost_mtd_cents)} />
          <Kpi label="IA interne (estimée) MTD" value={formatCents(s.internal_ai_cost_mtd_cents)} />
          <Kpi label="Providers MTD" value={formatCents(s.provider_cost_mtd_cents)} />
          <Kpi label="MRR" value={formatCents(s.mrr_cents)} />
          <Kpi label="Marge brute" value={formatCents(s.gross_margin_cents)} />
        </div>
      ) : null}

      <div className="mb-6 grid gap-4 lg:grid-cols-2">
        <Card className="p-4">
          <h3 className="mb-2 text-sm font-medium text-muted">Coûts journaliers (USD)</h3>
          <SimpleLineChart
            data={chart}
            lines={[
              { key: "openai", name: "OpenAI", color: "#3ecf8e" },
              { key: "anthropic", name: "Anthropic", color: "#a78bfa" },
              { key: "aws", name: "AWS", color: "#f5a524" },
            ]}
          />
        </Card>
        <Card className="p-4">
          <h3 className="mb-2 text-sm font-medium text-muted">AWS par service (top 12)</h3>
          <SimpleBarChart
            data={awsBars}
            bars={[{ key: "amount", name: "USD", color: "#f5a524" }]}
          />
        </Card>
      </div>

      <Card className="mb-6 p-0">
        <div className="border-b border-line/60 px-4 py-3 text-sm font-medium">
          Réconciliation provider vs usage interne
        </div>
        {!d?.reconciliation?.length ? (
          <Empty title="Aucune réconciliation — lance une synchronisation" />
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>Jour</Th>
                <Th>Provider</Th>
                <Th>Facturé</Th>
                <Th>Interne</Th>
                <Th>Delta</Th>
                <Th>Notes</Th>
              </tr>
            </thead>
            <tbody>
              {d.reconciliation.map((r) => (
                <tr key={r.id} className="hover:bg-panel/40">
                  <Td>{r.day}</Td>
                  <Td>{r.provider}</Td>
                  <Td>{formatCents(r.provider_reported_cents)}</Td>
                  <Td>{formatCents(r.internal_usage_cents)}</Td>
                  <Td className={r.delta_cents > 500 ? "text-warn" : ""}>
                    {formatCents(r.delta_cents)}
                  </Td>
                  <Td className="max-w-xs truncate text-muted">{r.notes || "—"}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>

      <Card className="p-0">
        <div className="border-b border-line/60 px-4 py-3 text-sm font-medium">
          Snapshots bruts
        </div>
        {list.isLoading ? <Loading /> : null}
        {!list.isLoading && !d?.snapshots?.length ? (
          <Empty title="Aucun snapshot — configure les Admin keys puis sync" />
        ) : (
          <Table>
            <thead>
              <tr>
                <Th>Période</Th>
                <Th>Provider</Th>
                <Th>Montant</Th>
                <Th>Breakdown</Th>
                <Th>Source</Th>
                <Th>Fetched</Th>
              </tr>
            </thead>
            <tbody>
              {(d?.snapshots || []).slice(0, 100).map((s) => (
                <tr key={s.id} className="hover:bg-panel/40">
                  <Td className="whitespace-nowrap text-muted">
                    {formatDate(s.period_start)}
                  </Td>
                  <Td>{s.provider}</Td>
                  <Td>{formatCents(s.amount_cents)}</Td>
                  <Td className="max-w-sm truncate font-mono text-xs text-muted">
                    {JSON.stringify(s.breakdown)}
                  </Td>
                  <Td>{s.source}</Td>
                  <Td className="text-muted">{formatDate(s.fetched_at)}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Card>
    </div>
  );
}
