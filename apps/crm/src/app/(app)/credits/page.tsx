"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest, formatDate } from "@/lib/api";
import type { CreditTxn, PageMeta } from "@/lib/types";
import {
  Button,
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

// Revenue side: 1 credit sells for ~1.9¢ ($19 per 1000-credit pack — see
// Mokaid.Billing.Credits). Margin only makes sense on spend transactions.
const CREDIT_PRICE_CENTS = 1.9;

function spendMargin(kind: string, amount: number, costCents?: number | null): string {
  if (kind !== "spend" || amount >= 0 || !costCents) return "—";
  const revenue = Math.abs(amount) * CREDIT_PRICE_CENTS;
  if (revenue <= 0) return "—";
  const pct = ((revenue - costCents) / revenue) * 100;
  return `${pct.toFixed(0)}%`;
}

export default function CreditsPage() {
  const [page, setPage] = useState(1);
  const [workspaceId, setWorkspaceId] = useState("");
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState("");
  const [filterWs, setFilterWs] = useState("");
  const qc = useQueryClient();

  const { data, isLoading } = useQuery({
    queryKey: ["credits", page, filterWs],
    queryFn: () => {
      const params = new URLSearchParams({ page: String(page), per_page: "40" });
      if (filterWs.trim()) params.set("workspace_id", filterWs.trim());
      return apiRequest<{ data: CreditTxn[]; meta: PageMeta }>(
        `/api/admin/credits/transactions?${params}`,
      );
    },
  });

  const adjust = useMutation({
    mutationFn: () => {
      if (!reason.trim()) throw new Error("Motif obligatoire");
      const n = Number(amount);
      if (!Number.isFinite(n) || n === 0) throw new Error("Montant invalide");
      if (Math.abs(n) > 10_000_000) throw new Error("Montant trop élevé");
      return apiRequest("/api/admin/credits/adjust", {
        method: "POST",
        body: {
          workspace_id: workspaceId.trim(),
          amount: n,
          reason: reason.trim(),
          idempotency_key: `crm-${workspaceId.trim()}-${n}-${Date.now()}`,
        },
      });
    },
    onSuccess: () => {
      setAmount("");
      setReason("");
      qc.invalidateQueries({ queryKey: ["credits"] });
    },
  });

  return (
    <div>
      <PageHeader
        title="Crédits AI"
        description="Ledger des transactions et ajustements manuels opérateur (transactionnels + motif)."
      />
      <Card className="mb-4 flex flex-wrap items-end gap-3 p-4">
        <div>
          <div className="mb-1 text-xs text-muted">Workspace ID</div>
          <Input
            className="w-72"
            value={workspaceId}
            onChange={(e) => setWorkspaceId(e.target.value)}
            placeholder="uuid workspace"
          />
        </div>
        <div>
          <div className="mb-1 text-xs text-muted">Amount (+/-)</div>
          <Input
            type="number"
            className="w-32"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
          />
        </div>
        <div>
          <div className="mb-1 text-xs text-muted">Motif</div>
          <Input
            className="w-64"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Support ticket #…"
          />
        </div>
        <Button
          onClick={() => {
            if (confirm(`Ajuster ${amount} crédits pour ${workspaceId} ?`)) adjust.mutate();
          }}
          disabled={!workspaceId || !amount || !reason.trim() || adjust.isPending}
        >
          Ajuster
        </Button>
        {adjust.isError ? (
          <span className="text-sm text-danger">{(adjust.error as Error).message}</span>
        ) : null}
        {adjust.isSuccess ? <span className="text-sm text-success">OK</span> : null}
      </Card>

      <Input
        className="mb-4 max-w-xs"
        placeholder="Filtrer workspace id…"
        value={filterWs}
        onChange={(e) => {
          setPage(1);
          setFilterWs(e.target.value);
        }}
      />
      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && !data?.data?.length ? <Empty title="Aucune transaction" /> : null}
        {data?.data?.length ? (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>Date</Th>
                  <Th>Workspace</Th>
                  <Th>Kind</Th>
                  <Th>Amount</Th>
                  <Th>Coût provider</Th>
                  <Th>Marge</Th>
                  <Th>Balance after</Th>
                  <Th>Description</Th>
                </tr>
              </thead>
              <tbody>
                {data.data.map((t) => (
                  <tr key={t.id}>
                    <Td className="text-muted">{formatDate(t.inserted_at)}</Td>
                    <Td className="font-mono text-xs">{t.workspace_id.slice(0, 8)}…</Td>
                    <Td>{t.kind}</Td>
                    <Td className={t.amount < 0 ? "text-danger" : "text-success"}>
                      {t.amount}
                    </Td>
                    <Td className="text-muted">{formatCostCents(t.cost_cents)}</Td>
                    <Td>{spendMargin(t.kind, t.amount, t.cost_cents)}</Td>
                    <Td>{t.balance_after}</Td>
                    <Td className="text-muted">{t.description || "—"}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
            <Pagination page={data.meta.page} totalPages={data.meta.total_pages} onPage={setPage} />
          </>
        ) : null}
      </Card>
    </div>
  );
}
