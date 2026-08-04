"use client";

import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest, formatCents } from "@/lib/api";
import type { Plan } from "@/lib/types";
import {
  Button,
  Card,
  Empty,
  Input,
  Loading,
  PageHeader,
  Table,
  Td,
  Th,
  Textarea,
} from "@/components/ui";

export default function PlansPage() {
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ["plans"],
    queryFn: () => apiRequest<{ data: Plan[] }>("/api/admin/plans"),
  });

  const [edit, setEdit] = useState<Plan | null>(null);
  const [draft, setDraft] = useState({
    name: "",
    price_cents_monthly: 0,
    price_cents_yearly: 0,
    features: "",
  });

  const save = useMutation({
    mutationFn: () =>
      apiRequest(`/api/admin/plans/${edit!.id}`, {
        method: "PATCH",
        body: {
          name: draft.name,
          price_cents_monthly: Number(draft.price_cents_monthly),
          price_cents_yearly: Number(draft.price_cents_yearly),
          features: draft.features
            .split("\n")
            .map((s) => s.trim())
            .filter(Boolean),
        },
      }),
    onSuccess: () => {
      setEdit(null);
      qc.invalidateQueries({ queryKey: ["plans"] });
    },
  });

  return (
    <div>
      <PageHeader title="Forfaits" description="Catalogue billing_plans (prix, limites, features)." />
      <Card>
        {isLoading ? <Loading /> : null}
        {!isLoading && !data?.data?.length ? <Empty title="Aucun plan" /> : null}
        {data?.data?.length ? (
          <Table>
            <thead>
              <tr>
                <Th>Clé</Th>
                <Th>Nom</Th>
                <Th>Mensuel</Th>
                <Th>Annuel</Th>
                <Th>Limits</Th>
                <Th />
              </tr>
            </thead>
            <tbody>
              {data.data.map((p) => (
                <tr key={p.id} className="hover:bg-panel/40">
                  <Td className="font-mono text-xs">{p.key}</Td>
                  <Td className="font-medium">{p.name}</Td>
                  <Td>{formatCents(p.price_cents_monthly)}</Td>
                  <Td>{formatCents(p.price_cents_yearly)}</Td>
                  <Td className="max-w-xs truncate font-mono text-xs text-muted">
                    {JSON.stringify(p.limits)}
                  </Td>
                  <Td>
                    <Button
                      variant="ghost"
                      onClick={() => {
                        setEdit(p);
                        setDraft({
                          name: p.name,
                          price_cents_monthly: p.price_cents_monthly,
                          price_cents_yearly: p.price_cents_yearly,
                          features: (p.features || []).join("\n"),
                        });
                      }}
                    >
                      Éditer
                    </Button>
                  </Td>
                </tr>
              ))}
            </tbody>
          </Table>
        ) : null}
      </Card>

      {edit ? (
        <Card className="mt-4 space-y-3 p-5">
          <h2 className="font-medium">Éditer {edit.key}</h2>
          <Input value={draft.name} onChange={(e) => setDraft({ ...draft, name: e.target.value })} />
          <div className="flex gap-2">
            <Input
              type="number"
              value={draft.price_cents_monthly}
              onChange={(e) =>
                setDraft({ ...draft, price_cents_monthly: Number(e.target.value) })
              }
            />
            <Input
              type="number"
              value={draft.price_cents_yearly}
              onChange={(e) =>
                setDraft({ ...draft, price_cents_yearly: Number(e.target.value) })
              }
            />
          </div>
          <Textarea
            rows={5}
            value={draft.features}
            onChange={(e) => setDraft({ ...draft, features: e.target.value })}
            placeholder="Une feature par ligne"
          />
          <div className="flex gap-2">
            <Button onClick={() => save.mutate()} disabled={save.isPending}>
              Enregistrer
            </Button>
            <Button variant="ghost" onClick={() => setEdit(null)}>
              Annuler
            </Button>
          </div>
        </Card>
      ) : null}
    </div>
  );
}
