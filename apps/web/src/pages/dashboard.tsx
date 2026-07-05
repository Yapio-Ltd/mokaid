import { Suspense, lazy, useMemo } from "react";
import { Bot, CheckCircle2, ClipboardList, Users } from "lucide-react";
import { useAgents, useTasks, useWorkspace } from "@/api/hooks";
import { KpiCard } from "@/components/ui/kpi-card";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { Avatar } from "@/components/ui/avatar";
import { AgentStatusBadge, PriorityBadge, TaskStatusBadge } from "@/components/ui/status";
import { ProgressBar } from "@/components/ui/progress-bar";
import { Skeleton } from "@/components/ui/skeleton";
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

  const show3dOffice = workspaceData?.data.feature_toggles?.["3d_office"] !== false;

  const agents = agentsData?.data ?? [];
  const counts = agentsData?.meta.counts;
  const tasks = tasksData?.data ?? [];

  const activeTasks = useMemo(
    () => tasks.filter((t) => ["in_progress", "in_review", "waiting"].includes(t.status)).slice(0, 6),
    [tasks],
  );

  const selectedAgent = agents.find((a) => a.id === selectedAgentId) ?? null;

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
        {/* KPI row */}
        <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
          <KpiCard
            label="Total Agents"
            value={counts?.total ?? "·"}
            icon={<Bot size={20} />}
            tone="primary"
          />
          <KpiCard
            label="Active Now"
            value={counts?.active ?? "·"}
            icon={<Users size={20} />}
            tone="success"
          />
          <KpiCard
            label="Tasks in Progress"
            value={tasksData?.meta.counts?.in_progress ?? "·"}
            icon={<ClipboardList size={20} />}
            tone="info"
          />
          <KpiCard
            label="Completed Today"
            value={tasksData?.meta.completed_today ?? "·"}
            icon={<CheckCircle2 size={20} />}
            tone="warning"
          />
        </div>

        {/* 3D office (toggleable from Workspace Settings) */}
        {show3dOffice && (
          <Card className="overflow-hidden">
            <div className="relative h-[420px]">
              <Suspense fallback={<Skeleton className="h-full w-full rounded-none" />}>
                <OfficeCanvas agents={agents} onSelectAgent={selectAgent} />
              </Suspense>
            </div>
          </Card>
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
                    <tr className="border-b border-border text-[11px] uppercase tracking-wide text-text-muted">
                      <th className="px-5 py-2 font-medium">Task</th>
                      <th className="px-3 py-2 font-medium">Agent</th>
                      <th className="px-3 py-2 font-medium">Status</th>
                      <th className="px-3 py-2 font-medium">Priority</th>
                      <th className="px-5 py-2 font-medium">Progress</th>
                    </tr>
                  </thead>
                  <tbody>
                    {activeTasks.map((task) => (
                      <tr
                        key={task.id}
                        className="border-b border-border/50 transition-colors last:border-0 hover:bg-surface-hover"
                      >
                        <td className="max-w-[220px] truncate px-5 py-2.5 font-medium text-text">
                          {task.title}
                        </td>
                        <td className="px-3 py-2.5 text-text-secondary">
                          <span className="flex items-center gap-2">
                            <Avatar
                              name={task.assigned_agent_name}
                              size="xs"
                              isAi={task.assigned_agent_kind === "ai"}
                            />
                            <span className="max-w-[110px] truncate">
                              {task.assigned_agent_name ?? "Unassigned"}
                            </span>
                          </span>
                        </td>
                        <td className="px-3 py-2.5">
                          <TaskStatusBadge status={task.status} />
                        </td>
                        <td className="px-3 py-2.5">
                          <PriorityBadge priority={task.priority} />
                        </td>
                        <td className="px-5 py-2.5">
                          <div className="flex items-center gap-2">
                            <ProgressBar value={task.progress_percent} className="w-16" />
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
                : agents.slice(0, 7).map((agent) => (
                    <button
                      key={agent.id}
                      onClick={() => selectAgent(agent.id)}
                      className="flex w-full items-center gap-3 rounded-md px-3 py-2 text-left transition-colors hover:bg-surface-hover mk-focus-ring"
                    >
                      <Avatar
                        name={agent.display_name}
                        size="sm"
                        isAi={agent.kind === "ai"}
                        color={agent.avatar_config?.primary_color}
                      />
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

      {/* Agent profile panel */}
      <AgentProfilePanel agent={selectedAgent} onClose={() => selectAgent(null)} />
    </div>
  );
}
