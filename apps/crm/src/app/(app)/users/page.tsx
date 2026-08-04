"use client";

import Link from "next/link";
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { apiRequest, formatDate } from "@/lib/api";
import type { AdminUser, PageMeta } from "@/lib/types";
import {
  Badge,
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
  statusTone,
} from "@/components/ui";

export default function UsersPage() {
  const [q, setQ] = useState("");
  const [status, setStatus] = useState("all");
  const [page, setPage] = useState(1);

  const { data, isLoading } = useQuery({
    queryKey: ["users", q, status, page],
    queryFn: () => {
      const params = new URLSearchParams({ page: String(page), per_page: "25" });
      if (q.trim()) params.set("q", q.trim());
      if (status !== "all") params.set("status", status);
      return apiRequest<{ data: AdminUser[]; meta: PageMeta }>(`/api/admin/users?${params}`);
    },
  });

  return (
    <div>
      <PageHeader title="Utilisateurs" description="Comptes plateforme et appartenances workspace." />
      <div className="mb-4 flex flex-wrap gap-2">
        <Input
          placeholder="Rechercher email ou nom…"
          value={q}
          onChange={(e) => {
            setPage(1);
            setQ(e.target.value);
          }}
          className="max-w-xs"
        />
        <Select
          value={status}
          onChange={(e) => {
            setPage(1);
            setStatus(e.target.value);
          }}
        >
          <option value="all">Tous les statuts</option>
          <option value="active">active</option>
          <option value="suspended">suspended</option>
          <option value="disabled">disabled</option>
        </Select>
      </div>
      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && (!data?.data?.length) ? <Empty title="Aucun utilisateur" /> : null}
        {data?.data?.length ? (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>Utilisateur</Th>
                  <Th>Statut</Th>
                  <Th>Admin platef.</Th>
                  <Th>Dernière conn.</Th>
                  <Th>Inscrit</Th>
                </tr>
              </thead>
              <tbody>
                {data.data.map((u) => (
                  <tr key={u.id} className="hover:bg-panel/40">
                    <Td>
                      <Link href={`/users/${u.id}`} className="font-medium text-accent hover:underline">
                        {u.full_name}
                      </Link>
                      <div className="text-xs text-muted">{u.email}</div>
                    </Td>
                    <Td>
                      <Badge tone={statusTone(u.status)}>{u.status || "active"}</Badge>
                    </Td>
                    <Td>{u.is_platform_admin ? <Badge tone="accent">oui</Badge> : "—"}</Td>
                    <Td className="text-muted">{formatDate(u.last_login_at)}</Td>
                    <Td className="text-muted">{formatDate(u.inserted_at)}</Td>
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
