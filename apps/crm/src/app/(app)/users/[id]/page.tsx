"use client";

import { useParams, useRouter } from "next/navigation";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { apiRequest, formatDate } from "@/lib/api";
import type { AdminUser } from "@/lib/types";
import {
  Badge,
  Button,
  Card,
  Input,
  Loading,
  PageHeader,
  Select,
  statusTone,
} from "@/components/ui";

export default function UserDetailPage() {
  const { id } = useParams<{ id: string }>();
  const router = useRouter();
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ["user", id],
    queryFn: () => apiRequest<{ data: AdminUser }>(`/api/admin/users/${id}`),
  });

  const user = data?.data;
  const [fullName, setFullName] = useState("");
  const [status, setStatus] = useState("active");
  const [locale, setLocale] = useState("en");
  const [timezone, setTimezone] = useState("UTC");
  const [isAdmin, setIsAdmin] = useState(false);
  const [password, setPassword] = useState("");
  const [msg, setMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!user) return;
    setFullName(user.full_name || "");
    setStatus(user.status || "active");
    setLocale(user.locale || "en");
    setTimezone(user.timezone || "UTC");
    setIsAdmin(!!user.is_platform_admin);
  }, [user]);

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
        },
      }),
    onSuccess: () => {
      setMsg("Enregistré");
      qc.invalidateQueries({ queryKey: ["user", id] });
      qc.invalidateQueries({ queryKey: ["users"] });
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
      {msg ? <p className="mb-4 text-sm text-muted">{msg}</p> : null}
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
          <label className="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={isAdmin}
              onChange={(e) => setIsAdmin(e.target.checked)}
            />
            Platform admin
          </label>
          <div className="flex gap-2 pt-2">
            <Button onClick={() => save.mutate()} disabled={save.isPending}>
              Enregistrer
            </Button>
            <Badge tone={statusTone(user.status)}>{user.status || "active"}</Badge>
          </div>
          <p className="text-xs text-muted">Dernière connexion : {formatDate(user.last_login_at)}</p>
        </Card>

        <Card className="space-y-3 p-5">
          <h2 className="text-sm font-medium uppercase tracking-wider text-muted">
            Réinitialiser mot de passe
          </h2>
          <Input
            type="password"
            placeholder="Nouveau mot de passe (min 10)"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          <Button
            variant="secondary"
            disabled={password.length < 10 || resetPw.isPending}
            onClick={() => resetPw.mutate()}
          >
            Réinitialiser
          </Button>

          <h2 className="pt-4 text-sm font-medium uppercase tracking-wider text-muted">
            Memberships
          </h2>
          <ul className="space-y-2">
            {(user.memberships || []).map((m) => (
              <li key={m.id} className="rounded-lg border border-line/70 px-3 py-2 text-sm">
                <div className="font-medium">{m.workspace_name}</div>
                <div className="text-xs text-muted">
                  {m.role_name} · {m.status}
                </div>
              </li>
            ))}
            {!user.memberships?.length ? (
              <li className="text-sm text-muted">Aucun workspace</li>
            ) : null}
          </ul>
        </Card>
      </div>
    </div>
  );
}
