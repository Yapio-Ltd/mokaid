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

export default function CreditsPage() {
  const [page, setPage] = useState(1);
  const [workspaceId, setWorkspaceId] = useState("");
  const [amount, setAmount] = useState("");
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
    mutationFn: () =>
      apiRequest("/api/admin/credits/adjust", {
        method: "POST",
        body: { workspace_id: workspaceId.trim(), amount: Number(amount) },
      }),
    onSuccess: () => {
      setAmount("");
      qc.invalidateQueries({ queryKey: ["credits"] });
    },
  });

  return (
    <div>
      <PageHeader
        title="Crédits AI"
        description="Ledger des transactions et ajustements manuels opérateur."
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
        <Button
          onClick={() => adjust.mutate()}
          disabled={!workspaceId || !amount || adjust.isPending}
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
