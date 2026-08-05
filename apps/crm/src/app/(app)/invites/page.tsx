"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest, formatDate } from "@/lib/api";
import type { Invite, PageMeta } from "@/lib/types";
import {
  Button,
  Card,
  Empty,
  Loading,
  PageHeader,
  Pagination,
  Table,
  Td,
  Th,
  Badge,
  statusTone,
} from "@/components/ui";

export default function InvitesPage() {
  const [page, setPage] = useState(1);
  const qc = useQueryClient();

  const { data, isLoading } = useQuery({
    queryKey: ["invites", page],
    queryFn: () =>
      apiRequest<{ data: Invite[]; meta: PageMeta }>(
        `/api/admin/invites?page=${page}&per_page=40`,
      ),
  });

  const cancel = useMutation({
    mutationFn: (id: string) =>
      apiRequest(`/api/admin/invites/${id}`, { method: "DELETE" }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["invites"] }),
  });

  return (
    <div>
      <PageHeader title="Invitations" description="Invites workspace en attente ou expirées." />
      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && !data?.data?.length ? <Empty title="Aucune invitation" /> : null}
        {data?.data?.length ? (
          <>
            <Table>
              <thead>
                <tr>
                  <Th>Email</Th>
                  <Th>Workspace</Th>
                  <Th>Rôle</Th>
                  <Th>Statut</Th>
                  <Th>Expire</Th>
                  <Th />
                </tr>
              </thead>
              <tbody>
                {data.data.map((i) => (
                  <tr key={i.id} className="hover:bg-panel/40">
                    <Td>{i.email}</Td>
                    <Td>{i.workspace_name || i.workspace_id}</Td>
                    <Td>{i.role_name || "—"}</Td>
                    <Td>
                      <Badge tone={statusTone(i.status)}>{i.status}</Badge>
                    </Td>
                    <Td className="text-muted">{formatDate(i.expires_at)}</Td>
                    <Td>
                      {i.status === "pending" ? (
                        <Button
                          variant="ghost"
                          onClick={() => cancel.mutate(i.id)}
                          disabled={cancel.isPending}
                        >
                          Annuler
                        </Button>
                      ) : null}
                    </Td>
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
