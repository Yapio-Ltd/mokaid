import * as Tabs from "@radix-ui/react-tabs";
import { Link2, Sparkles } from "lucide-react";
import type { Agent } from "@/api/types";
import { useTasks } from "@/api/hooks";
import { DetailPanel } from "@/components/ui/detail-panel";
import { Avatar } from "@/components/ui/avatar";
import { AgentStatusBadge, TaskStatusBadge } from "@/components/ui/status";
import { ProgressBar } from "@/components/ui/progress-bar";
import { Badge } from "@/components/ui/badge";
import { formatRelative } from "@/lib/format";

const tabClass =
  "flex-1 border-b-2 border-transparent px-2 py-2 text-xs font-medium text-text-muted transition-colors data-[state=active]:border-primary data-[state=active]:text-text";

export function AgentProfilePanel({
  agent,
  onClose,
}: {
  agent: Agent | null;
  onClose: () => void;
}) {
  const { data: tasksData } = useTasks(agent ? { agent_id: agent.id } : {});
  const agentTasks = agent ? (tasksData?.data ?? []).filter((t) => t.assigned_agent_id === agent.id) : [];
  const currentTask = agentTasks.find((t) => t.id === agent?.current_task_id) ?? agentTasks.find((t) => t.status === "in_progress");

  return (
    <DetailPanel open={agent != null} onClose={onClose} title="Agent Profile">
      {agent && (
        <div className="flex flex-col">
          <div className="flex flex-col items-center gap-3 border-b border-border px-5 py-6">
            <Avatar
              name={agent.display_name}
              size="xl"
              isAi={agent.kind === "ai"}
              color={agent.avatar_config?.primary_color}
            />
            <div className="text-center">
              <h3 className="text-base font-bold text-text">{agent.display_name}</h3>
              <p className="text-xs text-text-muted">{agent.role_title ?? "Agent"}</p>
            </div>
            <div className="flex items-center gap-2">
              <AgentStatusBadge status={agent.status} />
              {agent.kind === "ai" ? (
                <Badge tone="primary">
                  <Sparkles size={10} /> AI Agent
                </Badge>
              ) : (
                <Badge tone="info">
                  <Link2 size={10} /> {agent.linked_user_name ?? "Human-linked"}
                </Badge>
              )}
            </div>
            {agent.performance_score != null && (
              <div className="w-full">
                <div className="mb-1 flex justify-between text-[11px] text-text-muted">
                  <span>Performance</span>
                  <span className="font-semibold text-text">{agent.performance_score}%</span>
                </div>
                <ProgressBar value={agent.performance_score} tone="success" />
              </div>
            )}
          </div>

          <Tabs.Root defaultValue="overview">
            <Tabs.List className="flex border-b border-border px-3">
              <Tabs.Trigger value="overview" className={tabClass}>
                Overview
              </Tabs.Trigger>
              <Tabs.Trigger value="skills" className={tabClass}>
                Skills
              </Tabs.Trigger>
              <Tabs.Trigger value="tasks" className={tabClass}>
                Tasks
              </Tabs.Trigger>
            </Tabs.List>

            <Tabs.Content value="overview" className="space-y-4 px-5 py-4">
              {currentTask ? (
                <div>
                  <p className="mb-2 text-[11px] font-semibold uppercase tracking-wide text-text-muted">
                    Current Task
                  </p>
                  <div className="mk-card-raised space-y-2 p-3">
                    <p className="text-xs font-semibold text-text">{currentTask.title}</p>
                    <div className="flex items-center justify-between">
                      <TaskStatusBadge status={currentTask.status} />
                      <span className="text-[11px] text-text-muted">
                        {currentTask.progress_percent}%
                      </span>
                    </div>
                    <ProgressBar value={currentTask.progress_percent} />
                  </div>
                </div>
              ) : (
                <p className="text-xs text-text-muted">No task in progress.</p>
              )}

              <div className="grid grid-cols-2 gap-3 text-center">
                <div className="mk-card-raised p-3">
                  <p className="text-lg font-bold text-text">
                    {agentTasks.filter((t) => t.status === "in_progress").length}
                  </p>
                  <p className="text-[11px] text-text-muted">In progress</p>
                </div>
                <div className="mk-card-raised p-3">
                  <p className="text-lg font-bold text-text">
                    {agentTasks.filter((t) => t.status === "completed").length}
                  </p>
                  <p className="text-[11px] text-text-muted">Completed</p>
                </div>
              </div>

              <div className="space-y-1.5 text-xs">
                <div className="flex justify-between">
                  <span className="text-text-muted">Department</span>
                  <span className="text-text">{agent.department ?? "—"}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-text-muted">Last active</span>
                  <span className="text-text">{formatRelative(agent.last_active_at)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-text-muted">AI enabled</span>
                  <span className="text-text">{agent.ai_enabled ? "Yes" : "No"}</span>
                </div>
              </div>
            </Tabs.Content>

            <Tabs.Content value="skills" className="space-y-3 px-5 py-4">
              {agent.skills.length ? (
                agent.skills.map((skill) => (
                  <div key={skill.name}>
                    <div className="mb-1 flex justify-between text-[11px]">
                      <span className="font-medium text-text">{skill.name}</span>
                      <span className="text-text-muted">{skill.level}%</span>
                    </div>
                    <ProgressBar value={skill.level ?? 0} />
                  </div>
                ))
              ) : (
                <p className="text-xs text-text-muted">No skills recorded.</p>
              )}
            </Tabs.Content>

            <Tabs.Content value="tasks" className="space-y-2 px-5 py-4">
              {agentTasks.length ? (
                agentTasks.slice(0, 8).map((task) => (
                  <div key={task.id} className="mk-card-raised flex items-center justify-between gap-2 p-3">
                    <p className="min-w-0 flex-1 truncate text-xs font-medium text-text">
                      {task.title}
                    </p>
                    <TaskStatusBadge status={task.status} />
                  </div>
                ))
              ) : (
                <p className="text-xs text-text-muted">No tasks assigned.</p>
              )}
            </Tabs.Content>
          </Tabs.Root>
        </div>
      )}
    </DetailPanel>
  );
}
