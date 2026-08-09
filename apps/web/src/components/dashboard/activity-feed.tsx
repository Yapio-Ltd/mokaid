import { useMemo } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  Loader2,
  Radio,
  ShieldAlert,
} from "lucide-react";
import type { Agent, Task } from "@/api/types";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { useToolActivityStore } from "@/stores/tool-activity-store";
import { useUiStore } from "@/stores/ui-store";
import { formatRelative } from "@/lib/format";

interface FeedEntry {
  key: string;
  taskId: string;
  icon: "working" | "done" | "failed" | "approval";
  text: string;
  detail?: string;
  at: string;
}

/**
 * Realtime team pulse: what every agent is doing, finished, or waiting on —
 * derived from the tasks the realtime channel already keeps fresh, plus the
 * live tool-activity stream for in-flight missions.
 */
export function ActivityFeed({ tasks, agents }: { tasks: Task[]; agents: Agent[] }) {
  const feeds = useToolActivityStore((s) => s.feeds);

  const entries = useMemo(() => {
    const agentName = (task: Task) =>
      task.assigned_agent_name ??
      agents.find((a) => a.id === task.assigned_agent_id)?.display_name ??
      "An agent";

    const result: FeedEntry[] = [];
    for (const task of tasks) {
      const run = task.latest_run;
      if (!run) continue;
      const name = agentName(task);

      if (["queued", "running"].includes(run.status)) {
        const live = (feeds[task.id] ?? [])
          .filter((e) => e.status === "running")
          .at(-1);
        result.push({
          key: `${run.id}-working`,
          taskId: task.id,
          icon: "working",
          text: `${name} is working on “${task.title}”`,
          detail: live?.description,
          at: run.started_at ?? run.inserted_at,
        });
      } else if (run.status === "waiting_for_approval") {
        result.push({
          key: `${run.id}-approval`,
          taskId: task.id,
          icon: "approval",
          text: `${name} is waiting for your approval on “${task.title}”`,
          at: run.started_at ?? run.inserted_at,
        });
      } else if (run.status === "completed" && run.completed_at) {
        result.push({
          key: `${run.id}-done`,
          taskId: task.id,
          icon: "done",
          text: `${name} finished “${task.title}”`,
          at: run.completed_at,
        });
      } else if (run.status === "failed" && run.completed_at) {
        result.push({
          key: `${run.id}-failed`,
          taskId: task.id,
          icon: "failed",
          text: `${name} hit a wall on “${task.title}”`,
          at: run.completed_at,
        });
      }
    }

    // Live items first, then most recent.
    const rank = (e: FeedEntry) => (e.icon === "working" || e.icon === "approval" ? 1 : 0);
    return result
      .sort((a, b) => rank(b) - rank(a) || new Date(b.at).getTime() - new Date(a.at).getTime())
      .slice(0, 8);
  }, [tasks, agents, feeds]);

  const selectTask = useUiStore((s) => s.selectTask);

  if (entries.length === 0) return null;

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-1.5">
          <Radio size={13} className="text-primary-light" />
          Live activity
        </CardTitle>
      </CardHeader>
      <CardBody className="space-y-0.5 px-2 pb-3">
        {entries.map((entry) => (
          <button
            key={entry.key}
            type="button"
            onClick={() => selectTask(entry.taskId)}
            className="flex w-full items-start gap-2.5 rounded-md px-3 py-2 text-left transition-colors hover:bg-surface-hover mk-focus-ring"
          >
            <span className="mt-0.5 shrink-0">
              {entry.icon === "working" && (
                <Loader2 size={13} className="animate-spin text-info" />
              )}
              {entry.icon === "done" && <CheckCircle2 size={13} className="text-success" />}
              {entry.icon === "failed" && <AlertTriangle size={13} className="text-danger" />}
              {entry.icon === "approval" && <ShieldAlert size={13} className="text-warning" />}
            </span>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-[12px] text-text">{entry.text}</span>
              {entry.detail && (
                <span className="block truncate text-[10px] text-text-muted">{entry.detail}</span>
              )}
            </span>
            <span className="shrink-0 text-[10px] text-text-muted">
              {formatRelative(entry.at)}
            </span>
          </button>
        ))}
      </CardBody>
    </Card>
  );
}
