"use client";

import Link from "next/link";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { apiRequest, formatDate } from "@/lib/api";
import type { PageMeta, WorkspaceRow } from "@/lib/types";
import {
  Badge,
  Card,
  Empty,
  Input,
  Loading,
  PageHeader,
  Pagination,
  Table,
  Td,
  Th,
  statusTone,
} from "@/components/ui";

export default function WorkspacesPage() {
  const [q, setQ] = useState("");
  const [page, setPage] = useState(1);

  const { data, isLoading } = useQuery({
    queryKey: ["workspaces", q, page],
    queryFn: () => {
      const params = new URLSearchParams({ page: String(page), per_page: "25" });
      if (q.trim()) params.set("q", q.trim());
      return apiRequest<{ data: WorkspaceRow[]; meta: PageMeta }>(
        `/api/admin/workspaces?${params}`,
      );
    },
  });

  return (
    <div>
      <PageHeader title="Workspaces" description="Tenants clients, plans et membres." />
      <Input
        className="mb-4 max-w-xs"
        placeholder="Rechercher…"
        value={q}
        onChange={(e) => {
          setPage(1);
          setQ(e.target.value);
        }}
      />
      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && !data?.data?.length ? <Empty title="Aucun workspace" /> : null}
        {data?.data?.length ? (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>Workspace</Th>
                  <Th>Membres</Th>
                  <Th>Plan</Th>
                  <Th>Abo</Th>
                  <Th>Créé</Th>
                </tr>
              </thead>
              <tbody>
                {data.data.map((w) => (
                  <tr key={w.id} className="hover:bg-panel/40">
                    <Td>
                      <Link
                        href={`/workspaces/${w.id}`}
                        className="font-medium text-accent hover:underline"
                      >
                        {w.name}
                      </Link>
                      <div className="text-xs text-muted">{w.slug}</div>
                    </Td>
                    <Td>{w.member_count ?? 0}</Td>
                    <Td>{w.subscription?.plan?.name || "—"}</Td>
                    <Td>
                      {w.subscription ? (
                        <Badge tone={statusTone(w.subscription.status)}>
                          {w.subscription.status}
                        </Badge>
                      ) : (
                        "—"
                      )}
                    </Td>
                    <Td className="text-muted">{formatDate(w.inserted_at)}</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
            <Pagination
              page={data.meta.page}
              totalPages={data.meta.total_pages}
              onPage={setPage}
            />
          </>
        ) : null}
      </Card>
    </div>
  );
}
