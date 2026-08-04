"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { apiRequest, formatDate } from "@/lib/api";
import type { PageMeta, UsageEvent } from "@/lib/types";
import {
  Card,
  Empty,
  Input,
  Loading,
  PageHeader,
  Pagination,
  Table,
  Td,
  Th,
} from "@/components/ui";

function formatCostCents(cents?: number | null): string {
  if (!cents) return "—";
  return `$${(cents / 100).toFixed(cents < 100 ? 3 : 2)}`;
}

function formatQuantity(e: UsageEvent): string {
  if (e.quantity == null) return "—";
  const qty =
    e.quantity >= 1000 ? `${(e.quantity / 1000).toFixed(1)}k` : String(e.quantity);
  return e.unit ? `${qty} ${e.unit}` : qty;
}

function metadataSummary(metadata: Record<string, unknown> | null): string {
  if (!metadata) return "—";
  const model = metadata["model"];
  const tokens = metadata["total_tokens"] ?? metadata["tokens"];
  const parts = [
    typeof model === "string" ? model : null,
    tokens != null ? `${tokens} tokens` : null,
  ].filter(Boolean);
  return parts.length > 0 ? parts.join(" · ") : "—";
}

export default function UsagePage() {
  const [page, setPage] = useState(1);
  const [filterWs, setFilterWs] = useState("");

  const { data, isLoading } = useQuery({
    queryKey: ["usage-events", page, filterWs],
    queryFn: () => {
      const params = new URLSearchParams({ page: String(page), per_page: "40" });
      if (filterWs.trim()) params.set("workspace_id", filterWs.trim());
      return apiRequest<{ data: UsageEvent[]; meta: PageMeta }>(
        `/api/admin/usage-events?${params}`,
      );
    },
  });

  const events = data?.data ?? [];
  const pageCost = events.reduce((sum, e) => sum + (e.cost_cents ?? 0), 0);

  return (
    <div>
      <PageHeader
        title="Usage AI"
        description="Événements d'usage bruts (tokens, images…) et coût provider réel — la face « coût Mokaid » du ledger crédits."
      />

      <div className="mb-4 flex flex-wrap items-center gap-3">
        <Input
          className="max-w-xs"
          placeholder="Filtrer workspace id…"
          value={filterWs}
          onChange={(e) => {
            setPage(1);
            setFilterWs(e.target.value);
          }}
        />
        <span className="text-sm text-muted">
          Coût provider (page) : <span className="text-ink">{formatCostCents(pageCost)}</span>
        </span>
      </div>

      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && events.length === 0 ? <Empty title="Aucun événement d'usage" /> : null}
        {events.length > 0 ? (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>Date</Th>
                  <Th>Workspace</Th>
                  <Th>Acteur</Th>
                  <Th>Événement</Th>
                  <Th>Quantité</Th>
                  <Th>Coût provider</Th>
                  <Th>Détails</Th>
                </tr>
              </thead>
              <tbody>
                {events.map((e) => (
                  <tr key={e.id}>
                    <Td className="text-muted">{formatDate(e.occurred_at)}</Td>
                    <Td className="font-mono text-xs">{e.workspace_id.slice(0, 8)}…</Td>
                    <Td className="text-muted">
                      {e.actor_type ?? "—"}
                      {e.actor_id ? (
                        <span className="font-mono text-xs"> {e.actor_id.slice(0, 8)}…</span>
                      ) : null}
                    </Td>
                    <Td>{e.event_type}</Td>
                    <Td>{formatQuantity(e)}</Td>
                    <Td>{formatCostCents(e.cost_cents)}</Td>
                    <Td className="text-muted">{metadataSummary(e.metadata)}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
            {data?.meta ? (
              <Pagination
                page={data.meta.page}
                totalPages={data.meta.total_pages}
                onPage={setPage}
              />
            ) : null}
          </>
        ) : null}
      </Card>
    </div>
  );
}
