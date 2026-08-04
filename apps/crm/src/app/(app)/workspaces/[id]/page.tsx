"use client";

import { useParams, useRouter } from "next/navigation";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { apiRequest, formatCents } from "@/lib/api";
import type { WorkspaceRow } from "@/lib/types";
import {
  Badge,
  Button,
  Card,
  Input,
  Loading,
  PageHeader,
  statusTone,
  Textarea,
} from "@/components/ui";

export default function WorkspaceDetailPage() {
  const { id } = useParams<{ id: string }>();
  const router = useRouter();
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ["workspace", id],
    queryFn: () =>
      apiRequest<{
        data: WorkspaceRow & {
          members?: Array<{
            id: string;
            full_name?: string;
            email?: string;
            role_name?: string;
            status?: string;
          }>;
        };
      }>(`/api/admin/workspaces/${id}`),
  });

  const w = data?.data;
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [timezone, setTimezone] = useState("UTC");
  const [creditsAdj, setCreditsAdj] = useState("");
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!w) return;
    setName(w.name || "");
    setDescription(w.description || "");
    setTimezone(w.timezone || "UTC");
  }, [w]);

  const save = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/workspaces/${id}`, {
        method: "PATCH",
        body: { name, description, timezone },
      }),
    onSuccess: () => {
      setMsg("Workspace mis à jour");
      qc.invalidateQueries({ queryKey: ["workspace", id] });
    },
    onError: (e: Error) => setMsg(e.message),
  });

  const softDelete = useMutation({
    mutationFn: () => apiRequest(`/api/admin/workspaces/${id}`, { method: "DELETE" }),
    onSuccess: () => {
      setMsg("Workspace soft-deleted");
      qc.invalidateQueries({ queryKey: ["workspace", id] });
    },
    onError: (e: Error) => setMsg(e.message),
  });

  const restore = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/workspaces/${id}/restore`, { method: "POST" }),
    onSuccess: () => {
      setMsg("Workspace restauré");
      qc.invalidateQueries({ queryKey: ["workspace", id] });
    },
    onError: (e: Error) => setMsg(e.message),
  });

  const adjustCredits = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/credits/adjust`, {
        method: "POST",
        body: { workspace_id: id, amount: Number(creditsAdj) },
      }),
    onSuccess: () => {
      setCreditsAdj("");
      setMsg("Crédits ajustés");
      qc.invalidateQueries({ queryKey: ["workspace", id] });
    },
    onError: (e: Error) => setMsg(e.message),
  });

  if (isLoading) return <Loading />;
  if (!w) return <p className="text-danger">Introuvable</p>;

  return (
    <div>
      <PageHeader
        title={w.name}
        description={w.slug}
        actions={
          <Button variant="ghost" onClick={() => router.push("/workspaces")}>
            Retour
          </Button>
        }
      />
      {msg ? <p className="mb-4 text-sm text-muted">{msg}</p> : null}
      <div className="grid gap-4 lg:grid-cols-2">
        <Card className="space-y-3 p-5">
          <h2 className="text-sm font-medium uppercase tracking-wider text-muted">Édition</h2>
          <Input value={name} onChange={(e) => setName(e.target.value)} />
          <Textarea
            rows={3}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="Description"
          />
          <Input value={timezone} onChange={(e) => setTimezone(e.target.value)} />
          <div className="flex flex-wrap gap-2">
            <Button onClick={() => save.mutate()} disabled={save.isPending}>
              Enregistrer
            </Button>
            {w.deleted_at ? (
              <Button variant="secondary" onClick={() => restore.mutate()}>
                Restaurer
              </Button>
            ) : (
              <Button variant="danger" onClick={() => softDelete.mutate()}>
                Soft delete
              </Button>
            )}
          </div>
        </Card>

        <Card className="space-y-3 p-5">
          <h2 className="text-sm font-medium uppercase tracking-wider text-muted">
            Abonnement
          </h2>
          {w.subscription ? (
            <div className="space-y-1 text-sm">
              <div className="flex items-center gap-2">
                <span>{w.subscription.plan?.name}</span>
                <Badge tone={statusTone(w.subscription.status)}>{w.subscription.status}</Badge>
              </div>
              <div className="text-muted">
                Crédits balance : {w.subscription.credits_balance} · inclus :{" "}
                {w.subscription.included_credits_remaining}
              </div>
              <div className="text-muted">
                Prix plan :{" "}
                {formatCents(w.subscription.plan?.price_cents_monthly || 0)}/mois
              </div>
            </div>
          ) : (
            <p className="text-sm text-muted">Pas d&apos;abonnement</p>
          )}
          <div className="flex gap-2 pt-2">
            <Input
              type="number"
              placeholder="+/- crédits"
              value={creditsAdj}
              onChange={(e) => setCreditsAdj(e.target.value)}
              className="max-w-[140px]"
            />
            <Button
              variant="secondary"
              disabled={!creditsAdj || adjustCredits.isPending}
              onClick={() => adjustCredits.mutate()}
            >
              Ajuster crédits
            </Button>
          </div>

          <h2 className="pt-4 text-sm font-medium uppercase tracking-wider text-muted">
            Membres ({w.members?.length || 0})
          </h2>
          <ul className="max-h-64 space-y-1 overflow-y-auto text-sm">
            {(w.members || []).map((m) => (
              <li key={m.id} className="flex justify-between border-b border-line/50 py-1.5">
                <span>
                  {m.full_name}
                  <span className="ml-2 text-xs text-muted">{m.email}</span>
                </span>
                <span className="text-xs text-muted">
                  {m.role_name} · {m.status}
                </span>
              </li>
            ))}
          </ul>
        </Card>
      </div>
    </div>
  );
}
