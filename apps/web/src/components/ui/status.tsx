import type { AgentStatus, TaskStatus, TaskPriority } from "@mokaid/shared-types";
import { Badge } from "./badge";

const agentStatusTone: Record<string, "success" | "warning" | "primary" | "danger" | "muted"> = {
  active: "success",
  busy: "warning",
  idle: "primary",
  waiting: "warning",
  blocked: "danger",
  away: "warning",
  offline: "muted",
  archived: "muted",
};

const agentStatusLabel: Record<string, string> = {
  active: "Active",
  busy: "Busy",
  idle: "Idle",
  waiting: "Waiting",
  blocked: "Blocked",
  away: "Away",
  offline: "Offline",
  archived: "Archived",
};

export function AgentStatusBadge({ status }: { status: AgentStatus | string }) {
  return (
    <Badge tone={agentStatusTone[status] ?? "default"} dot>
      {agentStatusLabel[status] ?? status}
    </Badge>
  );
}

const taskStatusTone: Record<string, "default" | "info" | "primary" | "warning" | "danger" | "success" | "muted"> = {
  to_do: "default",
  in_progress: "info",
  in_review: "primary",
  waiting: "warning",
  blocked: "danger",
  completed: "success",
  canceled: "muted",
  overdue: "danger",
};

const taskStatusLabel: Record<string, string> = {
  to_do: "To Do",
  in_progress: "In Progress",
  in_review: "In Review",
  waiting: "Waiting",
  blocked: "Blocked",
  completed: "Completed",
  canceled: "Canceled",
  overdue: "Overdue",
};

export function TaskStatusBadge({ status }: { status: TaskStatus | string }) {
  return <Badge tone={taskStatusTone[status] ?? "default"}>{taskStatusLabel[status] ?? status}</Badge>;
}

const priorityTone: Record<string, "muted" | "info" | "warning" | "danger"> = {
  low: "muted",
  medium: "info",
  high: "warning",
  urgent: "danger",
};

export function PriorityBadge({ priority }: { priority: TaskPriority | string }) {
  const label = priority.charAt(0).toUpperCase() + priority.slice(1);
  return <Badge tone={priorityTone[priority] ?? "default"}>{label}</Badge>;
}
