"use client";

import { useQuery } from "@tanstack/react-query";
import { apiRequest, formatCents } from "@/lib/api";
import type { Metrics } from "@/lib/types";
import { Kpi, Loading, PageHeader } from "@/components/ui";

export default function DashboardPage() {
  const { data, isLoading, error } = useQuery({
    queryKey: ["metrics"],
    queryFn: () => apiRequest<{ data: Metrics }>("/api/admin/metrics"),
  });

  const m = data?.data;

  return (
    <div>
      <PageHeader
        title="Vue d'ensemble"
        description="Indicateurs plateforme — utilisateurs, abonnements et facturation."
      />
      {isLoading ? <Loading /> : null}
      {error ? (
        <p className="text-sm text-danger">{(error as Error).message}</p>
      ) : null}
      {m ? (
        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <Kpi label="Utilisateurs" value={m.users_total} hint={`${m.users_active} actifs`} />
          <Kpi label="Nouveaux (30j)" value={m.new_users_30d} />
          <Kpi label="Workspaces" value={m.workspaces_total} />
          <Kpi label="MRR estimé" value={formatCents(m.mrr_cents)} />
          <Kpi label="Abos actifs" value={m.subscriptions_active} />
          <Kpi label="Past due" value={m.subscriptions_past_due} />
          <Kpi label="Factures pending" value={m.invoices_pending} />
        </div>
      ) : null}
    </div>
  );
}
