/** Phoenix Channels event contracts. Payloads are compact; clients refetch details. */

export type WorkspaceEvent =
  | "agent.created"
  | "agent.updated"
  | "agent.status_changed"
  | "agent.presence_changed"
  | "agent.linked_user_changed"
  | "agent.current_task_changed"
  | "task.created"
  | "task.updated"
  | "task.status_changed"
  | "task.assigned"
  | "task.progress_changed"
  | "task.completed"
  | "task.approval_required"
  | "task.comment_added"
  | "project.created"
  | "project.updated"
  | "project.progress_changed"
  | "project.activity_added"
  | "knowledge.uploaded"
  | "knowledge.processing_started"
  | "knowledge.indexed"
  | "knowledge.failed"
  | "calendar.event_created"
  | "calendar.event_updated"
  | "leave_request.created"
  | "leave_request.approved"
  | "leave_request.rejected"
  | "billing.usage_updated"
  | "notification.created";

export interface AgentStatusChangedPayload {
  agent_id: string;
  status: string;
  presence_status: string;
  current_task_id: string | null;
}

export interface TaskStatusChangedPayload {
  task_id: string;
  status: string;
  progress_percent: number;
  assigned_agent_id: string | null;
}

export interface PresenceMeta {
  user_id: string;
  member_id: string | null;
  agent_id: string | null;
  status: "online" | "away";
  current_page: string | null;
  current_task_id: string | null;
  last_seen_at: string;
}

export function workspaceTopic(workspaceId: string): string {
  return `workspace:${workspaceId}`;
}

export function agentTopic(agentId: string): string {
  return `agent:${agentId}`;
}

export function taskTopic(taskId: string): string {
  return `task:${taskId}`;
}

export function notificationsTopic(userId: string): string {
  return `notifications:${userId}`;
}
