"use client";

import { useParams, useRouter } from "next/navigation";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import Link from "next/link";
import { apiRequest, formatCents, formatDate } from "@/lib/api";
import type { AdminUser, UserSummary } from "@/lib/types";
import {
  Badge,
  Button,
  Card,
  Input,
  Loading,
  PageHeader,
  Select,
  Table,
  Td,
  Th,
  statusTone,
} from "@/components/ui";

type Tab = "profil" | "billing" | "usage" | "logins" | "audit";

export default function UserDetailPage() {
  const { id } = useParams<{ id: string }>();
  const router = useRouter();
  const qc = useQueryClient();
  const [tab, setTab] = useState<Tab>("profil");
  const [reason, setReason] = useState("");
  const [msg, setMsg] = useState<string | null>(null);

  const { data, isLoading } = useQuery({
    queryKey: ["user-summary", id],
    queryFn: () => apiRequest<{ data: UserSummary }>(`/api/admin/users/${id}/summary`),
  });

  const summary = data?.data;
  const user = summary?.user;

  const [fullName, setFullName] = useState("");
  const [status, setStatus] = useState("active");
  const [locale, setLocale] = useState("en");
  const [timezone, setTimezone] = useState("UTC");
  const [isAdmin, setIsAdmin] = useState(false);
  const [notes, setNotes] = useState("");
  const [password, setPassword] = useState("");

  useEffect(() => {
    if (!user) return;
    setFullName(user.full_name || "");
    setStatus(user.status || "active");
    setLocale(user.locale || "en");
    setTimezone(user.timezone || "UTC");
    setIsAdmin(!!user.is_platform_admin);
    setNotes(user.operator_notes || "");
  }, [user]);

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ["user-summary", id] });
    qc.invalidateQueries({ queryKey: ["users"] });
  };

  const save = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/users/${id}`, {
        method: "PATCH",
        body: {
          full_name: fullName,
          status,
          locale,
          timezone,
          is_platform_admin: isAdmin,
          operator_notes: notes,
        },
      }),
    onSuccess: () => {
      setMsg("Enregistré");
      invalidate();
    },
    onError: (e: Error) => setMsg(e.message),
  });

  const ban = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/users/${id}/ban`, {
        method: "POST",
        body: { reason: reason || "Banned by operator" },
      }),
    onSuccess: () => {
      setMsg("Utilisateur banni");
      setReason("");
      invalidate();
    },
    onError: (e: Error) => setMsg(e.message),
  });

  const unban = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/users/${id}/unban`, { method: "POST", body: {} }),
    onSuccess: () => {
      setMsg("Bannissement levé");
      invalidate();
    },
    onError: (e: Error) => setMsg(e.message),
  });

  const scheduleDel = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/users/${id}/schedule-deletion`, {
        method: "POST",
        body: { reason: reason || "Scheduled deletion", days: 30 },
      }),
    onSuccess: () => {
      setMsg("Suppression planifiée dans 30 jours");
      invalidate();
    },
    onError: (e: Error) => setMsg(e.message),
  });

  const cancelDel = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/users/${id}/cancel-deletion`, { method: "POST", body: {} }),
    onSuccess: () => {
      setMsg("Suppression annulée");
      invalidate();
    },
    onError: (e: Error) => setMsg(e.message),
  });

  const resetPw = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/users/${id}/reset-password`, {
        method: "POST",
        body: { password },
      }),
    onSuccess: () => {
      setPassword("");
      setMsg("Mot de passe réinitialisé");
    },
    onError: (e: Error) => setMsg(e.message),
  });

  if (isLoading) return <Loading />;
  if (!user) return <p className="text-danger">Utilisateur introuvable</p>;

  const tabs: Array<{ id: Tab; label: string }> = [
    { id: "profil", label: "Profil" },
    { id: "billing", label: "Billing & crédits" },
    { id: "usage", label: "Usage AI" },
    { id: "logins", label: "Connexions" },
    { id: "audit", label: "Audit" },
  ];

  return (
    <div>
      <PageHeader
        title={user.full_name}
        description={user.email}
        actions={
          <Button variant="ghost" onClick={() => router.push("/users")}>
            Retour
          </Button>
        }
      />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <Badge tone={statusTone(user.status || "active")}>{user.status}</Badge>
        {user.is_platform_admin ? <Badge tone="accent">platform admin</Badge> : null}
        {user.banned_at ? (
          <Badge tone="danger">banni {formatDate(user.banned_at)}</Badge>
        ) : null}
        {user.deletion_scheduled_at ? (
          <Badge tone="warn">suppression {formatDate(user.deletion_scheduled_at)}</Badge>
        ) : null}
        <span className="text-xs text-muted">
          auth={user.auth_provider} · mfa={user.mfa_enabled ? "on" : "off"} · last login{" "}
          {formatDate(user.last_login_at)}
        </span>
      </div>

      {msg ? <p className="mb-4 text-sm text-muted">{msg}</p> : null}

      <div className="mb-4 flex flex-wrap gap-1 border-b border-line/60 pb-2">
        {tabs.map((t) => (
          <button
            key={t.id}
            type="button"
            onClick={() => setTab(t.id)}
            className={`rounded-lg px-3 py-1.5 text-sm ${
              tab === t.id ? "bg-accentSoft text-ink" : "text-muted hover:bg-panel"
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {tab === "profil" ? (
        <div className="grid gap-4 lg:grid-cols-2">
          <Card className="space-y-3 p-5">
            <h2 className="text-sm font-medium uppercase tracking-wider text-muted">Profil</h2>
            <label className="block text-xs text-muted">Nom</label>
            <Input value={fullName} onChange={(e) => setFullName(e.target.value)} />
            <label className="block text-xs text-muted">Statut</label>
            <Select value={status} onChange={(e) => setStatus(e.target.value)}>
              <option value="active">active</option>
              <option value="suspended">suspended</option>
              <option value="disabled">disabled</option>
            </Select>
            <label className="block text-xs text-muted">Locale</label>
            <Select value={locale} onChange={(e) => setLocale(e.target.value)}>
              <option value="en">en</option>
              <option value="fr">fr</option>
              <option value="he">he</option>
            </Select>
            <label className="block text-xs text-muted">Timezone</label>
            <Input value={timezone} onChange={(e) => setTimezone(e.target.value)} />
            <label className="block text-xs text-muted">Notes opérateur</label>
            <Input value={notes} onChange={(e) => setNotes(e.target.value)} />
            <label className="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                checked={isAdmin}
                onChange={(e) => setIsAdmin(e.target.checked)}
              />
              Platform admin
            </label>
            <Button onClick={() => save.mutate()} disabled={save.isPending}>
              Enregistrer
            </Button>
          </Card>

          <div className="space-y-4">
            <Card className="space-y-3 p-5">
              <h2 className="text-sm font-medium uppercase tracking-wider text-muted">
                Modération
              </h2>
              {user.ban_reason ? (
                <p className="text-sm text-muted">Motif ban : {user.ban_reason}</p>
              ) : null}
              <Input
                placeholder="Motif (obligatoire recommandé)"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
              />
              <div className="flex flex-wrap gap-2">
                {!user.banned_at ? (
                  <Button
                    variant="danger"
                    onClick={() => {
                      if (confirm("Bannir cet utilisateur ?")) ban.mutate();
                    }}
                    disabled={ban.isPending}
                  >
                    Bannir
                  </Button>
                ) : (
                  <Button onClick={() => unban.mutate()} disabled={unban.isPending}>
                    Lever le ban
                  </Button>
                )}
                {!user.deletion_scheduled_at ? (
                  <Button
                    variant="ghost"
                    onClick={() => {
                      if (
                        confirm(
                          "Planifier la suppression/anonymisation dans 30 jours ?",
                        )
                      )
                        scheduleDel.mutate();
                    }}
                    disabled={scheduleDel.isPending}
                  >
                    Suppression différée (30j)
                  </Button>
                ) : (
                  <Button onClick={() => cancelDel.mutate()} disabled={cancelDel.isPending}>
                    Annuler suppression
                  </Button>
                )}
              </div>
            </Card>

            <Card className="space-y-3 p-5">
              <h2 className="text-sm font-medium uppercase tracking-wider text-muted">
                Reset password
              </h2>
              <Input
                type="password"
                placeholder="Nouveau mot de passe (≥10)"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
              />
              <Button
                onClick={() => resetPw.mutate()}
                disabled={password.length < 10 || resetPw.isPending}
              >
                Réinitialiser
              </Button>
            </Card>

            <Card className="p-5">
              <h2 className="mb-3 text-sm font-medium uppercase tracking-wider text-muted">
                Workspaces
              </h2>
              <ul className="space-y-2 text-sm">
                {(user.memberships || []).map((m) => (
                  <li key={m.id} className="flex justify-between gap-2">
                    <Link
                      href={`/workspaces/${m.workspace_id}`}
                      className="text-accent hover:underline"
                    >
                      {m.workspace_name || m.workspace_id}
                    </Link>
                    <span className="text-muted">
                      {m.role_name} · {m.status}
                    </span>
                  </li>
                ))}
                {!user.memberships?.length ? (
                  <li className="text-muted">Aucun workspace</li>
                ) : null}
              </ul>
            </Card>
          </div>
        </div>
      ) : null}

      {tab === "billing" ? (
        <div className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-3">
            <Card className="p-4">
              <div className="text-xs text-muted">Coût IA 30j</div>
              <div className="text-xl font-medium">
                {formatCents(summary?.usage_cost_30d_cents || 0)}
              </div>
            </Card>
            <Card className="p-4">
              <div className="text-xs text-muted">Abonnements</div>
              <div className="text-xl font-medium">{summary?.subscriptions?.length || 0}</div>
            </Card>
            <Card className="p-4">
              <div className="text-xs text-muted">Factures</div>
              <div className="text-xl font-medium">{summary?.invoices?.length || 0}</div>
            </Card>
          </div>
          <Card>
            <div className="border-b border-line/60 px-4 py-3 text-sm font-medium">
              Abonnements
            </div>
            <Table>
              <thead>
                <tr>
                  <Th>Workspace</Th>
                  <Th>Plan</Th>
                  <Th>Status</Th>
                  <Th>Crédits</Th>
                </tr>
              </thead>
              <tbody>
                {(summary?.subscriptions || []).map((s) => (
                  <tr key={s.id}>
                    <Td>{s.workspace_name || s.workspace_id}</Td>
                    <Td>{s.plan?.name || "—"}</Td>
                    <Td>
                      <Badge tone={statusTone(s.status)}>{s.status}</Badge>
                    </Td>
                    <Td>
                      {s.credits_balance} + {s.included_credits_remaining} inclus
                    </Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </Card>
          <Card>
            <div className="border-b border-line/60 px-4 py-3 text-sm font-medium">
              Transactions crédits
            </div>
            <Table>
              <thead>
                <tr>
                  <Th>Date</Th>
                  <Th>Kind</Th>
                  <Th>Amount</Th>
                  <Th>Workspace</Th>
                </tr>
              </thead>
              <tbody>
                {(summary?.credit_transactions || []).map((t) => (
                  <tr key={t.id}>
                    <Td className="text-muted">{formatDate(t.inserted_at)}</Td>
                    <Td>{t.kind}</Td>
                    <Td>{t.amount}</Td>
                    <Td className="font-mono text-xs">{t.workspace_id.slice(0, 8)}…</Td>
                  </tr>
                ))}
              </tbody>
            </Table>
          </Card>
        </div>
      ) : null}

      {tab === "usage" ? (
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Date</Th>
                <Th>Type</Th>
                <Th>Qty</Th>
                <Th>Coût</Th>
              </tr>
            </thead>
            <tbody>
              {(summary?.usage_events || []).map((e) => (
                <tr key={e.id}>
                  <Td className="text-muted">{formatDate(e.occurred_at)}</Td>
                  <Td>{e.event_type}</Td>
                  <Td>
                    {e.quantity} {e.unit}
                  </Td>
                  <Td>{formatCents(e.cost_cents || 0)}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </Card>
      ) : null}

      {tab === "logins" ? (
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Date</Th>
                <Th>Méthode</Th>
                <Th>IP</Th>
                <Th>UA</Th>
              </tr>
            </thead>
            <tbody>
              {(summary?.logins || []).map((l) => (
                <tr key={l.id}>
                  <Td className="text-muted">{formatDate(l.occurred_at)}</Td>
                  <Td>{l.auth_method}</Td>
                  <Td>{l.ip_address || "—"}</Td>
                  <Td className="max-w-xs truncate text-xs text-muted">{l.user_agent}</Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </Card>
      ) : null}

      {tab === "audit" ? (
        <Card>
          <Table>
            <thead>
              <tr>
                <Th>Date</Th>
                <Th>Action</Th>
                <Th>Acteur</Th>
                <Th>Meta</Th>
              </tr>
            </thead>
            <tbody>
              {(summary?.audit_logs || []).map((l) => (
                <tr key={l.id}>
                  <Td className="text-muted">{formatDate(l.occurred_at)}</Td>
                  <Td className="font-mono text-xs">{l.action}</Td>
                  <Td>{l.actor_name}</Td>
                  <Td className="max-w-xs truncate text-xs text-muted">
                    {JSON.stringify(l.metadata)}
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
        </Card>
      ) : null}
    </div>
  );
}
