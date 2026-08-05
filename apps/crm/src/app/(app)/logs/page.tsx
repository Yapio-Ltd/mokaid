"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { apiRequest, formatDate } from "@/lib/api";
import type { PageMeta, UnifiedLog } from "@/lib/types";
import {
  Card,
  Empty,
  Input,
  Loading,
  PageHeader,
  Pagination,
  Select,
  Table,
  Td,
  Th,
} from "@/components/ui";

export default function LogsPage() {
  const [page, setPage] = useState(1);
  const [source, setSource] = useState("all");
  const [q, setQ] = useState("");

  const { data, isLoading } = useQuery({
    queryKey: ["logs", page, source, q],
    queryFn: () => {
      const params = new URLSearchParams({
        page: String(page),
        per_page: "50",
        source,
      });
      if (q.trim()) params.set("q", q.trim());
      return apiRequest<{ data: UnifiedLog[]; meta: PageMeta }>(`/api/admin/logs?${params}`);
    },
  });

  return (
    <div>
      <PageHeader
        title="Logs globaux"
        description="Audits plateforme, connexions, et logs CloudWatch (filtrés + redacted)."
      />
      <div className="mb-4 flex flex-wrap gap-2">
        <Select
          className="w-44"
          value={source}
          onChange={(e) => {
            setPage(1);
            setSource(e.target.value);
          }}
        >
          <option value="all">Toutes sources</option>
          <option value="audit">Audit métier</option>
          <option value="platform_audit">Audit opérateur</option>
          <option value="logins">Connexions</option>
          <option value="cloudwatch">CloudWatch</option>
        </Select>
        <Input
          className="max-w-sm"
          placeholder="Recherche…"
          value={q}
          onChange={(e) => {
            setPage(1);
            setQ(e.target.value);
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
                  <Th>Source</Th>
                  <Th>Acteur</Th>
                  <Th>Action</Th>
                  <Th>Message</Th>
                  <Th>IP</Th>
                </tr>
              </thead>
              <tbody>
                {data.data.map((l) => (
                  <tr key={l.id} className="hover:bg-panel/40">
                    <Td className="whitespace-nowrap text-muted">{formatDate(l.occurred_at)}</Td>
                    <Td className="text-xs uppercase text-muted">{l.source}</Td>
                    <Td className="max-w-[10rem] truncate">{l.actor || "—"}</Td>
                    <Td className="font-mono text-xs">{l.action}</Td>
                    <Td className="max-w-md truncate text-sm text-muted">{l.message || "—"}</Td>
                    <Td className="text-xs text-muted">{l.ip_address || "—"}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
            {data.meta ? (
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
