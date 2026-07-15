import { Suspense, lazy, useMemo } from "react";
import { AlertTriangle, Bot, CheckCircle2, ClipboardList, Users } from "lucide-react";
import { useAgents, useTasks, useWorkspace } from "@/api/hooks";
import { KpiCard } from "@/components/ui/kpi-card";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { AgentAvatar } from "@/components/agents/agent-avatar";
import { Avatar } from "@/components/ui/avatar";
import { AgentStatusBadge, TaskStatusBadge } from "@/components/ui/status";
import { ProgressBar } from "@/components/ui/progress-bar";
import { Skeleton } from "@/components/ui/skeleton";
import { AskBar } from "@/components/dashboard/ask-bar";
import { useUiStore } from "@/stores/ui-store";
import { AgentProfilePanel } from "@/components/agents/agent-profile-panel";
import { formatRelative } from "@/lib/format";

// Babylon.js is heavy, so load the 3D office chunk only when the dashboard renders.
const OfficeCanvas = lazy(() =>
  import("@/three/office-canvas").then((m) => ({ default: m.OfficeCanvas })),
);

export function DashboardPage() {
  const { data: agentsData, isLoading: agentsLoading } = useAgents();
  const { data: tasksData, isLoading: tasksLoading } = useTasks();
  const { data: workspaceData } = useWorkspace();
  const selectedAgentId = useUiStore((s) => s.selectedAgentId);
  const selectAgent = useUiStore((s) => s.selectAgent);
  const selectTask = useUiStore((s) => s.selectTask);
  const flashedTaskIds = useUiStore((s) => s.flashedTaskIds);

  const show3dOffice = workspaceData?.data.feature_toggles?.["3d_office"] !== false;

  const agents = agentsData?.data ?? [];
  const counts = agentsData?.meta.counts;
  const tasks = tasksData?.data ?? [];

  const activeTasks = useMemo(
    () =>
      tasks
        .filter(
          (t) =>
            ["in_progress", "in_review", "waiting"].includes(t.status) ||
            // Also show to_do tasks that have a run queued or an assigned agent,
            // so dispatched tasks don't vanish from the dashboard.
            (t.status === "to_do" &&
              (t.assigned_agent_id != null || t.latest_run != null)),
        )
        .slice(0, 6),
    [tasks],
  );

  // Detect a stale worker: any busy agent whose latest dispatched run has been
  // queued for more than 30 seconds with no progress.
  const workerDownWarning = useMemo(() => {
    const thirtySecsAgo = Date.now() - 30_000;
    return tasks.some(
      (t) =>
        t.latest_run?.status === "queued" &&
        new Date(t.latest_run.inserted_at).getTime() < thirtySecsAgo &&
        agents.some((a) => a.id === t.assigned_agent_id && a.status === "busy"),
    );
  }, [tasks, agents]);

  const selectedAgent = agents.find((a) => a.id === selectedAgentId) ?? null;

  return (
    <div className="relative h-full">
      <div className="min-w-0 space-y-5">
        {/* Command bar — dispatches to the best agent (same flow as office drop) */}
        <AskBar />

        {/* 3D office (toggleable from Workspace Settings) */}
        {show3dOffice && (
          <Card className="overflow-hidden">
            <div className="relative h-[560px]">
              <Suspense fallback={<Skeleton className="h-full w-full rounded-none" />}>
                <OfficeCanvas
                  agents={agents}
                  selectedAgentId={selectedAgentId}
                  onSelectAgent={selectAgent}
                />
              </Suspense>
            </div>
          </Card>
        )}

        {/* KPI row */}
        <div className="grid grid-cols-2 gap-3 xl:grid-cols-4">
          <KpiCard
            label="Total Agents"
            value={counts?.total ?? "·"}
            icon={<Bot size={18} strokeWidth={1.75} />}
            tone="primary"
          />
          <KpiCard
            label="Active Now"
            value={counts?.active ?? "·"}
            icon={<Users size={18} strokeWidth={1.75} />}
            tone="success"
          />
          <KpiCard
            label="Tasks in Progress"
            value={tasksData?.meta.counts?.in_progress ?? "·"}
            icon={<ClipboardList size={18} strokeWidth={1.75} />}
            tone="info"
          />
          <KpiCard
            label="Completed Today"
            value={tasksData?.meta.completed_today ?? "·"}
            icon={<CheckCircle2 size={18} strokeWidth={1.75} />}
            tone="warning"
          />
        </div>

        {/* Worker-down warning banner */}
        {workerDownWarning && (
          <div className="flex items-center gap-3 rounded-lg border border-yellow-500/40 bg-yellow-500/10 px-4 py-3 text-sm text-yellow-300">
            <AlertTriangle size={16} className="shrink-0" />
            <span>
              <strong>AI worker unreachable</strong> — a run has been queued for over 30 seconds.
              Make sure the AI worker service is running on <code className="rounded bg-yellow-900/40 px-1">:8100</code>.
            </span>
          </div>
        )}

        {/* Active tasks + team overview */}
        <div className="grid gap-5 xl:grid-cols-5">
          <Card className="xl:col-span-3">
            <CardHeader>
              <CardTitle>Active Tasks</CardTitle>
            </CardHeader>
            <CardBody className="px-0 pb-2">
              {tasksLoading ? (
                <div className="space-y-2 px-5 pb-4">
                  {[1, 2, 3].map((i) => (
                    <Skeleton key={i} className="h-11" />
                  ))}
                </div>
              ) : (
                <table className="w-full text-left text-xs">
                  <thead>
                    <tr className="text-[11px] uppercase tracking-wide text-text-muted">
                      <th className="px-5 py-2 font-medium">Task</th>
                      <th className="px-3 py-2 font-medium">Agent</th>
                      <th className="px-3 py-2 font-medium">Status</th>
                      <th className="px-3 py-2 font-medium">Run</th>
                      <th className="px-5 py-2 font-medium">Progress</th>
                    </tr>
                  </thead>
                  <tbody>
                    {activeTasks.map((task) => (
                      <tr
                        key={task.id}
                        onClick={() => selectTask(task.id)}
                        tabIndex={0}
                        onKeyDown={(e) => e.key === "Enter" && selectTask(task.id)}
                        className={
                          "cursor-pointer transition-colors hover:bg-surface-hover mk-focus-ring" +
                          (flashedTaskIds.includes(task.id) ? " animate-pulse bg-primary/10" : "")
                        }
                      >
                        <td className="max-w-[200px] truncate px-5 py-2.5 font-medium text-text">
                          {task.title}
                        </td>
                        <td className="px-3 py-2.5 text-text-secondary">
                          <span className="flex items-center gap-2">
                            {(() => {
                              const agent = agents.find((a) => a.id === task.assigned_agent_id);
                              return agent ? (
                                <AgentAvatar agent={agent} size="xs" showRing={false} showBadge={false} />
                              ) : (
                                <Avatar
                                  name={task.assigned_agent_name}
                                  size="xs"
                                  isAi={task.assigned_agent_kind === "ai"}
                                />
                              );
                            })()}
                            <span className="max-w-[90px] truncate">
                              {task.assigned_agent_name ?? "Unassigned"}
                            </span>
                          </span>
                        </td>
                        <td className="px-3 py-2.5">
                          <TaskStatusBadge status={task.status} />
                        </td>
                        <td className="px-3 py-2.5">
                          <RunStatusBadge run={task.latest_run} />
                        </td>
                        <td className="px-5 py-2.5">
                          <div className="flex items-center gap-2">
                            <ProgressBar value={task.progress_percent} className="w-14" />
                            <span className="text-[11px] text-text-muted">
                              {task.progress_percent}%
                            </span>
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </CardBody>
          </Card>

          <Card className="xl:col-span-2">
            <CardHeader>
              <CardTitle>Team Overview</CardTitle>
            </CardHeader>
            <CardBody className="space-y-1 px-2 pb-3">
              {agentsLoading
                ? [1, 2, 3, 4].map((i) => <Skeleton key={i} className="h-12" />)
                : agents.slice(0, 9).map((agent) => (
                    <button
                      key={agent.id}
                      onClick={() => selectAgent(agent.id)}
                      className="flex w-full items-center gap-3 rounded-md px-3 py-2 text-left transition-colors hover:bg-surface-hover mk-focus-ring"
                    >
                      <AgentAvatar agent={agent} size="sm" />
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-xs font-semibold text-text">
                          {agent.display_name}
                        </span>
                        <span className="block truncate text-[11px] text-text-muted">
                          {agent.role_title ?? agent.department ?? "Agent"} ·{" "}
                          {formatRelative(agent.last_active_at)}
                        </span>
                      </span>
                      <AgentStatusBadge status={agent.status} />
                    </button>
                  ))}
            </CardBody>
          </Card>
        </div>
      </div>

      {/* Agent profile panel — floats above the content so the 3D view keeps its size */}
      <AgentProfilePanel agent={selectedAgent} onClose={() => selectAgent(null)} overlay />
    </div>
  );
}

function RunStatusBadge({ run }: { run: { status: string; error: string | null } | null }) {
  if (!run) return <span className="text-[11px] text-text-muted">—</span>;

  const cfg: Record<string, { label: string; className: string }> = {
    queued:   { label: "Queued",   className: "bg-yellow-500/15 text-yellow-300" },
    running:  { label: "Running",  className: "bg-blue-500/15 text-blue-300" },
    failed:   { label: "Failed",   className: "bg-red-500/15 text-red-400" },
    completed: { label: "Done",    className: "bg-green-500/15 text-green-400" },
    waiting_for_approval: { label: "Approval", className: "bg-purple-500/15 text-purple-300" },
  };

  const { label, className } = cfg[run.status] ?? { label: run.status, className: "bg-surface-2 text-text-muted" };

  return (
    <span className={`inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium ${className}`}>
      {label}
      {run.status === "failed" && run.error && (
        <span className="ml-1 max-w-[80px] truncate opacity-70" title={run.error}>
          · {run.error}
        </span>
      )}
    </span>
  );
}
