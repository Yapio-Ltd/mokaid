import { useMemo, useState } from "react";
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
import { NewAgentModal } from "@/components/modals/new-agent-modal";
import { cn } from "@/lib/cn";
import { formatRelative } from "@/lib/format";

const kindFilters = [
  { value: "", label: "All" },
  { value: "ai", label: "AI Agents" },
  { value: "human_linked", label: "Human-linked" },
  { value: "hybrid", label: "Hybrid" },
];

const statusFilters = ["", "active", "busy", "idle", "waiting", "offline"];

export function AgentsPage() {
  const [kind, setKind] = useState("");
  const [status, setStatus] = useState("");
  const [search, setSearch] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [showNewAgent, setShowNewAgent] = useState(false);

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

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
        <div className="flex items-center justify-between gap-3">
          <div>
            <h1 className="text-xl font-bold text-text">Agents</h1>
            <p className="text-xs text-text-muted">
              Manage your AI, human-linked and hybrid workforce
            </p>
          </div>
          <Button onClick={() => setShowNewAgent(true)} data-tour="new-agent">
            <Plus size={14} /> New Agent
          </Button>
        </div>

        <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
          <KpiCard label="Total Agents" value={counts?.total ?? "·"} icon={<Bot size={20} />} tone="primary" />
          <KpiCard label="AI Agents" value={counts?.ai ?? "·"} icon={<Bot size={20} />} tone="info" />
          <KpiCard
            label="Human-linked"
            value={counts?.human_linked ?? "·"}
            icon={<Users size={20} />}
            tone="success"
          />
          <KpiCard label="Active Now" value={counts?.active ?? "·"} icon={<Users size={20} />} tone="warning" />
        </div>

        <div className="flex flex-wrap items-center gap-3">
          <div className="flex rounded-md bg-surface-raised p-0.5">
            {kindFilters.map((f) => (
              <button
                key={f.value}
                onClick={() => setKind(f.value)}
                className={cn(
                  "rounded px-3 py-1.5 text-xs font-medium transition-colors",
                  kind === f.value
                    ? "bg-primary-muted text-primary-light"
                    : "text-text-muted hover:text-text",
                )}
              >
                {f.label}
              </button>
            ))}
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
              <Button size="sm" onClick={() => setShowNewAgent(true)}>
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
                    onClick={() => setSelectedId(agent.id)}
                    className={cn(
                      "cursor-pointer transition-colors hover:bg-surface-hover",
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
      <NewAgentModal
        open={showNewAgent}
        onOpenChange={setShowNewAgent}
        onCreated={(id) => setSelectedId(id)}
      />
    </div>
  );
}
