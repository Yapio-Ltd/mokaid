"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest } from "@/lib/api";
import type { MemberRow, PageMeta } from "@/lib/types";
import {
  Badge,
  Button,
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

export default function MembersPage() {
  const [page, setPage] = useState(1);
  const [status, setStatus] = useState("all");
  const [workspaceId, setWorkspaceId] = useState("");
  const [editId, setEditId] = useState<string | null>(null);
  const [roleName, setRoleName] = useState("");
  const [memberStatus, setMemberStatus] = useState("active");
  const qc = useQueryClient();

  const { data, isLoading } = useQuery({
    queryKey: ["members", page, status, workspaceId],
    queryFn: () => {
      const params = new URLSearchParams({ page: String(page), per_page: "25" });
      if (status !== "all") params.set("status", status);
      if (workspaceId.trim()) params.set("workspace_id", workspaceId.trim());
      return apiRequest<{ data: MemberRow[]; meta: PageMeta }>(`/api/admin/members?${params}`);
    },
  });

  const update = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/members/${editId}`, {
        method: "PATCH",
        body: { role_name: roleName, status: memberStatus },
      }),
    onSuccess: () => {
      setEditId(null);
      qc.invalidateQueries({ queryKey: ["members"] });
    },
  });

  return (
    <div>
      <PageHeader title="Membres" description="Memberships cross-workspace." />
      <div className="mb-4 flex flex-wrap gap-2">
        <Input
          className="max-w-xs"
          placeholder="Workspace id…"
          value={workspaceId}
          onChange={(e) => {
            setPage(1);
            setWorkspaceId(e.target.value);
          }}
        />
        <Select
          value={status}
          onChange={(e) => {
            setPage(1);
            setStatus(e.target.value);
          }}
        >
          <option value="all">Tous</option>
          <option value="active">active</option>
          <option value="invited">invited</option>
          <option value="suspended">suspended</option>
          <option value="removed">removed</option>
        </Select>
      </div>
      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && !data?.data?.length ? <Empty title="Aucun membre" /> : null}
        {data?.data?.length ? (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>Membre</Th>
                  <Th>Workspace</Th>
                  <Th>Rôle</Th>
                  <Th>Statut</Th>
                  <Th />
                </tr>
              </thead>
              <tbody>
                {data.data.map((m) => (
                  <tr key={m.id} className="hover:bg-panel/40">
                    <Td>
                      <div className="font-medium">{m.full_name}</div>
                      <div className="text-xs text-muted">{m.email}</div>
                    </Td>
                    <Td className="text-sm">{m.workspace_name || m.workspace_id}</Td>
                    <Td>{m.role_name}</Td>
                    <Td>
                      <Badge tone={statusTone(m.status)}>{m.status}</Badge>
                    </Td>
                    <Td>
                      <Button
                        variant="ghost"
                        onClick={() => {
                          setEditId(m.id);
                          setRoleName(m.role_name || "Member");
                          setMemberStatus(m.status || "active");
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
          <Select value={roleName} onChange={(e) => setRoleName(e.target.value)}>
            {["Owner", "Admin", "Manager", "Member", "Viewer", "Agent User", "Billing Admin"].map(
              (r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ),
            )}
          </Select>
          <Select value={memberStatus} onChange={(e) => setMemberStatus(e.target.value)}>
            <option value="active">active</option>
            <option value="suspended">suspended</option>
            <option value="removed">removed</option>
          </Select>
          <Button onClick={() => update.mutate()} disabled={update.isPending}>
            Appliquer
          </Button>
          <Button variant="ghost" onClick={() => setEditId(null)}>
            Annuler
          </Button>
        </Card>
      ) : null}
    </div>
  );
}
