import { useMemo, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { Bot, Plus, Users } from "lucide-react";
import { useAgents } from "@/api/hooks";
import { KpiCard } from "@/components/ui/kpi-card";
import { AgentStatusBadge } from "@/components/ui/status";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { SearchInput } from "@/components/ui/search-input";
import { SkeletonRows } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/ui/empty-state";
import { AgentProfilePanel } from "@/components/agents/agent-profile-panel";
import { AgentAvatar } from "@/components/agents/agent-avatar";
import { PageHeader } from "@/components/ui/page-header";
import { cn } from "@/lib/cn";
import { formatRelative } from "@/lib/format";

const kindFilters = [
  { value: "", label: "All" },
  { value: "ai", label: "AI Agents" },
  { value: "human_linked", label: "Human-linked", soon: true },
  { value: "hybrid", label: "Hybrid", soon: true },
] as const;

const statusFilters = ["", "active", "busy", "idle", "waiting", "training", "offline"];

export function AgentsPage() {
  const navigate = useNavigate();
  const [kind, setKind] = useState("");
  const [status, setStatus] = useState("");
  const [search, setSearch] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const { data, isLoading } = useAgents({ kind: kind || undefined, status: status || undefined });

  const agents = useMemo(() => {
    const list = data?.data ?? [];
    if (!search) return list;
    const q = search.toLowerCase();
    return list.filter(
      (a) =>
        a.display_name.toLowerCase().includes(q) ||
        (a.role_title ?? "").toLowerCase().includes(q) ||
        (a.department ?? "").toLowerCase().includes(q),
    );
  }, [data, search]);

  const counts = data?.meta.counts;
  const selectedAgent = agents.find((a) => a.id === selectedId) ?? null;
  const atLimit = (counts?.total ?? 0) >= (counts?.limit ?? 1);

  const goNewAgent = () => void navigate({ to: "/agents/new" });

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
        <PageHeader
          title="Agents"
          subtitle={
            <>
              Manage your AI, human-linked and hybrid workforce
              {counts?.limit != null && (
                <>
                  {" "}
                  · {counts.total}/{counts.limit} seats used
                </>
              )}
            </>
          }
          actions={
            atLimit ? (
              <Link
                to="/billing"
                className="inline-flex h-9 items-center gap-1.5 rounded-md bg-primary px-4 text-sm font-semibold text-white shadow-sm shadow-primary/25 hover:bg-primary/90"
              >
                <Plus size={14} /> Upgrade for more seats
              </Link>
            ) : (
              <Button onClick={goNewAgent} data-tour="new-agent">
                <Plus size={14} /> New Agent
              </Button>
            )
          }
        />

        <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
          <div className="mk-fade-up">
            <KpiCard
              label="Active seats"
              value={`${counts?.total ?? "·"}/${counts?.limit ?? "·"}`}
              icon={<Bot size={20} />}
              tone="primary"
            />
          </div>
          <div className="mk-fade-up" style={{ animationDelay: "60ms" }}>
            <KpiCard label="AI Agents" value={counts?.ai ?? "·"} icon={<Bot size={20} />} tone="info" />
          </div>
          <div className="mk-fade-up" style={{ animationDelay: "120ms" }}>
            <KpiCard
              label="Human-linked"
              value={counts?.human_linked ?? "·"}
              icon={<Users size={20} />}
              tone="success"
            />
          </div>
          <div className="mk-fade-up" style={{ animationDelay: "180ms" }}>
            <KpiCard label="Active Now" value={counts?.active ?? "·"} icon={<Users size={20} />} tone="warning" />
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-3">
          <div className="flex rounded-md bg-surface-raised p-0.5">
            {kindFilters.map((f) => {
              const soon = "soon" in f && f.soon;
              return (
                <button
                  key={f.value}
                  type="button"
                  disabled={soon}
                  title={soon ? "Coming soon" : undefined}
                  onClick={() => {
                    if (!soon) setKind(f.value);
                  }}
                  className={cn(
                    "mk-chip inline-flex items-center gap-1.5 rounded px-3 py-1.5 text-xs font-medium",
                    soon
                      ? "cursor-not-allowed text-text-muted/55"
                      : kind === f.value
                        ? "mk-chip-active"
                        : "text-text-muted hover:text-text",
                  )}
                >
                  {f.label}
                  {soon && (
                    <span className="rounded px-1 py-px text-[9px] font-semibold uppercase tracking-wider text-primary-light/90 bg-primary/15">
                      Soon
                    </span>
                  )}
                </button>
              );
            })}
          </div>

          <select
            value={status}
            onChange={(e) => setStatus(e.target.value)}
            className="mk-input h-9 w-36"
            aria-label="Filter by status"
          >
            {statusFilters.map((s) => (
              <option key={s} value={s}>
                {s === "" ? "All statuses" : s.charAt(0).toUpperCase() + s.slice(1)}
              </option>
            ))}
          </select>

          <SearchInput
            placeholder="Search agents…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="w-64"
          />
        </div>

        {isLoading ? (
          <SkeletonRows rows={6} />
        ) : agents.length === 0 ? (
          <EmptyState
            icon={<Bot size={24} />}
            title="No agents found"
            description="Adjust your filters or create your first agent."
            action={
              <Button size="sm" onClick={goNewAgent}>
                <Plus size={13} /> New Agent
              </Button>
            }
          />
        ) : (
          <div className="mk-card overflow-x-auto">
            <table className="w-full text-left text-xs">
              <thead>
                <tr className="text-[11px] uppercase tracking-wide text-text-muted">
                  <th className="px-5 py-3 font-medium">Agent</th>
                  <th className="px-3 py-3 font-medium">Type</th>
                  <th className="px-3 py-3 font-medium">Linked To</th>
                  <th className="px-3 py-3 font-medium">Department</th>
                  <th className="px-3 py-3 font-medium">Status</th>
                  <th className="px-3 py-3 font-medium">Performance</th>
                  <th className="px-5 py-3 font-medium">Last Active</th>
                </tr>
              </thead>
              <tbody>
                {agents.map((agent) => (
                  <tr
                    key={agent.id}
                    onClick={() => {
                      if (agent.status === "training") {
                        void navigate({
                          to: "/agents/$agentId/training",
                          params: { agentId: agent.id },
                        });
                        return;
                      }
                      setSelectedId(agent.id);
                    }}
                    className={cn(
                      "mk-row cursor-pointer",
                      selectedId === agent.id && "bg-primary-muted/40",
                    )}
                  >
                    <td className="px-5 py-3.5">
                      <div className="flex items-center gap-3 overflow-visible">
                        <AgentAvatar agent={agent} size="sm" />
                        <div className="min-w-0">
                          <p className="truncate font-semibold text-text">{agent.display_name}</p>
                          <p className="truncate text-[11px] text-text-muted">
                            {agent.role_title ?? "·"}
                          </p>
                        </div>
                      </div>
                    </td>
                    <td className="px-3 py-3">
                      {agent.kind === "ai" ? (
                        <Badge tone="primary">AI</Badge>
                      ) : agent.kind === "hybrid" ? (
                        <Badge tone="warning">Hybrid</Badge>
                      ) : (
                        <Badge tone="info">Human</Badge>
                      )}
                    </td>
                    <td className="px-3 py-3 text-text-secondary">
                      {agent.linked_user_name ?? (agent.kind === "ai" ? "Autonomous" : "·")}
                    </td>
                    <td className="px-3 py-3 text-text-secondary">{agent.department ?? "·"}</td>
                    <td className="px-3 py-3">
                      <AgentStatusBadge status={agent.status} />
                    </td>
                    <td className="px-3 py-3">
                      <span
                        className={cn(
                          "font-semibold",
                          (agent.performance_score ?? 0) >= 90
                            ? "text-success"
                            : (agent.performance_score ?? 0) >= 75
                              ? "text-warning"
                              : "text-text-secondary",
                        )}
                      >
                        {agent.performance_score != null ? `${agent.performance_score}%` : "·"}
                      </span>
                    </td>
                    <td className="px-5 py-3 text-text-muted">
                      {formatRelative(agent.last_active_at)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <AgentProfilePanel agent={selectedAgent} onClose={() => setSelectedId(null)} />
    </div>
  );
}
