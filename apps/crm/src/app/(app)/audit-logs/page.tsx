"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { apiRequest, formatDate } from "@/lib/api";
import type { AuditLog, PageMeta } from "@/lib/types";
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

export default function AuditLogsPage() {
  const [page, setPage] = useState(1);
  const [action, setAction] = useState("");
  const [workspaceId, setWorkspaceId] = useState("");

  const { data, isLoading } = useQuery({
    queryKey: ["audit", page, action, workspaceId],
    queryFn: () => {
      const params = new URLSearchParams({ page: String(page), per_page: "50" });
      if (action.trim()) params.set("action", action.trim());
      if (workspaceId.trim()) params.set("workspace_id", workspaceId.trim());
      return apiRequest<{ data: AuditLog[]; meta: PageMeta }>(
        `/api/admin/audit-logs?${params}`,
      );
    },
  });

  return (
    <div>
      <PageHeader
        title="Audit logs"
        description="Journal des actions sensibles (plateforme et workspaces)."
      />
      <div className="mb-4 flex flex-wrap gap-2">
        <Input
          className="max-w-xs"
          placeholder="Filtrer action…"
          value={action}
          onChange={(e) => {
            setPage(1);
            setAction(e.target.value);
          }}
        />
        <Input
          className="max-w-xs"
          placeholder="Workspace id…"
          value={workspaceId}
          onChange={(e) => {
            setPage(1);
            setWorkspaceId(e.target.value);
          }}
        />
      </div>
      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && !data?.data?.length ? <Empty title="Aucun log" /> : null}
        {data?.data?.length ? (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>Date</Th>
                  <Th>Acteur</Th>
                  <Th>Action</Th>
                  <Th>Ressource</Th>
                  <Th>Metadata</Th>
                </tr>
              </thead>
              <tbody>
                {data.data.map((l) => (
                  <tr key={l.id} className="hover:bg-panel/40">
                    <Td className="whitespace-nowrap text-muted">{formatDate(l.occurred_at)}</Td>
                    <Td>
                      <div className="text-sm">{l.actor_name || "—"}</div>
                      <div className="text-xs text-muted">{l.actor_type}</div>
                    </Td>
                    <Td className="font-mono text-xs">{l.action}</Td>
                    <Td className="text-xs text-muted">
                      {l.resource_type}
                      {l.resource_id ? ` · ${String(l.resource_id).slice(0, 8)}` : ""}
                    </Td>
                    <Td className="max-w-xs truncate font-mono text-xs text-muted">
                      {l.metadata ? JSON.stringify(l.metadata) : "—"}
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
