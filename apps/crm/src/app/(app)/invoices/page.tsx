"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest, formatCents, formatDate } from "@/lib/api";
import type { Invoice, PageMeta } from "@/lib/types";
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

export default function InvoicesPage() {
  const [status, setStatus] = useState("all");
  const [page, setPage] = useState(1);
  const qc = useQueryClient();

  const { data, isLoading } = useQuery({
    queryKey: ["invoices", status, page],
    queryFn: () => {
      const params = new URLSearchParams({ page: String(page), per_page: "25" });
      if (status !== "all") params.set("status", status);
      return apiRequest<{ data: Invoice[]; meta: PageMeta }>(`/api/admin/invoices?${params}`);
    },
  });

  const markPaid = useMutation({
    mutationFn: (id: string) =>
      apiRequest(`/api/admin/invoices/${id}/mark-paid`, { method: "POST" }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["invoices"] }),
  });

  const voidInv = useMutation({
    mutationFn: (id: string) =>
      apiRequest(`/api/admin/invoices/${id}/void`, { method: "POST" }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["invoices"] }),
  });

  return (
    <div>
      <PageHeader title="Factures" description="Historique de paiement cross-workspace." />
      <Select
        className="mb-4"
        value={status}
        onChange={(e) => {
          setPage(1);
          setStatus(e.target.value);
        }}
      >
        <option value="all">Tous</option>
        <option value="pending">pending</option>
        <option value="paid">paid</option>
        <option value="void">void</option>
        <option value="expired">expired</option>
        <option value="draft">draft</option>
      </Select>
      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && !data?.data?.length ? <Empty title="Aucune facture" /> : null}
        {data?.data?.length ? (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>N°</Th>
                  <Th>Workspace</Th>
                  <Th>Montant</Th>
                  <Th>Statut</Th>
                  <Th>Kind</Th>
                  <Th>Émise</Th>
                  <Th />
                </tr>
              </thead>
              <tbody>
                {data.data.map((inv) => (
                  <tr key={inv.id} className="hover:bg-panel/40">
                    <Td className="font-mono text-xs">{inv.number}</Td>
                    <Td>{inv.workspace_name || inv.workspace_id}</Td>
                    <Td>
                      {formatCents(inv.amount_cents, inv.currency || "USD")}
                    </Td>
                    <Td>
                      <Badge tone={statusTone(inv.status)}>{inv.status}</Badge>
                    </Td>
                    <Td className="text-muted">{inv.kind}</Td>
                    <Td className="text-muted">{formatDate(inv.issued_at)}</Td>
                    <Td className="space-x-1">
                      {inv.status === "pending" || inv.status === "draft" ? (
                        <>
                          <Button
                            variant="ghost"
                            onClick={() => markPaid.mutate(inv.id)}
                            disabled={markPaid.isPending}
                          >
                            Marquer payée
                          </Button>
                          <Button
                            variant="ghost"
                            onClick={() => voidInv.mutate(inv.id)}
                            disabled={voidInv.isPending}
                          >
                            Void
                          </Button>
                        </>
                      ) : null}
                    </Td>
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
