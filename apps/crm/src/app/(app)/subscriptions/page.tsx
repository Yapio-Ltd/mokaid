"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest, formatDate } from "@/lib/api";
import type { PageMeta, Plan, Subscription } from "@/lib/types";
import {
  Badge,
  Button,
  Card,
  Empty,
  Loading,
  PageHeader,
  Pagination,
  Select,
  Table,
  Td,
  Th,
  statusTone,
} from "@/components/ui";

export default function SubscriptionsPage() {
  const [status, setStatus] = useState("all");
  const [page, setPage] = useState(1);
  const [editId, setEditId] = useState<string | null>(null);
  const [planKey, setPlanKey] = useState("");
  const [newStatus, setNewStatus] = useState("");
  const qc = useQueryClient();

  const plans = useQuery({
    queryKey: ["plans"],
    queryFn: () => apiRequest<{ data: Plan[] }>("/api/admin/plans"),
  });

  const { data, isLoading } = useQuery({
    queryKey: ["subscriptions", status, page],
    queryFn: () => {
      const params = new URLSearchParams({ page: String(page), per_page: "25" });
      if (status !== "all") params.set("status", status);
      return apiRequest<{ data: Subscription[]; meta: PageMeta }>(
        `/api/admin/subscriptions?${params}`,
      );
    },
  });

  const update = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/subscriptions/${editId}`, {
        method: "PATCH",
        body: {
          ...(planKey ? { plan_key: planKey } : {}),
          ...(newStatus ? { status: newStatus } : {}),
        },
      }),
    onSuccess: () => {
      setEditId(null);
      qc.invalidateQueries({ queryKey: ["subscriptions"] });
    },
  });

  return (
    <div>
      <PageHeader title="Abonnements" description="Plans et cycles de facturation par workspace." />
      <Select
        className="mb-4"
        value={status}
        onChange={(e) => {
          setPage(1);
          setStatus(e.target.value);
        }}
      >
        <option value="all">Tous</option>
        <option value="active">active</option>
        <option value="past_due">past_due</option>
        <option value="canceled">canceled</option>
      </Select>
      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && !data?.data?.length ? <Empty title="Aucun abonnement" /> : null}
        {data?.data?.length ? (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>Workspace</Th>
                  <Th>Plan</Th>
                  <Th>Statut</Th>
                  <Th>Cycle</Th>
                  <Th>Période fin</Th>
                  <Th>Crédits</Th>
                  <Th />
                </tr>
              </thead>
              <tbody>
                {data.data.map((s) => (
                  <tr key={s.id} className="hover:bg-panel/40">
                    <Td>
                      <div className="font-medium">{s.workspace_name || s.workspace_id}</div>
                      <div className="text-xs text-muted">{s.workspace_slug}</div>
                    </Td>
                    <Td>{s.plan?.name || "—"}</Td>
                    <Td>
                      <Badge tone={statusTone(s.status)}>{s.status}</Badge>
                    </Td>
                    <Td>{s.billing_cycle}</Td>
                    <Td className="text-muted">{formatDate(s.current_period_end)}</Td>
                    <Td>
                      {s.credits_balance} / {s.included_credits_remaining}
                    </Td>
                    <Td>
                      <Button
                        variant="ghost"
                        onClick={() => {
                          setEditId(s.id);
                          setPlanKey(s.plan?.key || "");
                          setNewStatus(s.status);
                        }}
                      >
                        Éditer
                      </Button>
                    </Td>
                  </tr>
                ))}
              </tbody>
            </Table>
            <Pagination page={data.meta.page} totalPages={data.meta.total_pages} onPage={setPage} />
          </>
        ) : null}
      </Card>

      {editId ? (
        <Card className="mt-4 flex flex-wrap items-end gap-3 p-4">
          <div>
            <div className="mb-1 text-xs text-muted">Plan</div>
            <Select value={planKey} onChange={(e) => setPlanKey(e.target.value)}>
              <option value="">— inchangé —</option>
              {(plans.data?.data || []).map((p) => (
                <option key={p.id} value={p.key}>
                  {p.name}
                </option>
              ))}
            </Select>
          </div>
          <div>
            <div className="mb-1 text-xs text-muted">Statut</div>
            <Select value={newStatus} onChange={(e) => setNewStatus(e.target.value)}>
              <option value="active">active</option>
              <option value="past_due">past_due</option>
              <option value="canceled">canceled</option>
              <option value="canceled_at_period_end">canceled_at_period_end</option>
            </Select>
          </div>
          <Button onClick={() => update.mutate()} disabled={update.isPending}>
            Appliquer
          </Button>
          <Button variant="ghost" onClick={() => setEditId(null)}>
            Annuler
          </Button>
          {update.isError ? (
            <span className="text-sm text-danger">{(update.error as Error).message}</span>
          ) : null}
        </Card>
      ) : null}
    </div>
  );
}
