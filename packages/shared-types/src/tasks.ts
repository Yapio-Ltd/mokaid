export type TaskStatus =
  | "to_do"
  | "in_progress"
  | "in_review"
  | "waiting"
  | "blocked"
  | "completed"
  | "canceled"
  | "overdue";

export type TaskPriority = "low" | "medium" | "high" | "urgent";

export type TaskResponseRating = "good" | "needs_improvement";

export interface TaskResponseFeedback {
  rating: TaskResponseRating;
  prompt: string | null;
  run_id: string | null;
  submitted_by_member_id: string | null;
  submitted_at: string;
}

export interface TaskResponseFeedbackInput {
  rating: TaskResponseRating;
  prompt?: string;
  run_id?: string;
}

export type ApprovalStatus = "pending" | "approved" | "rejected" | "edited" | "expired";

export type AiRunStatus =
  | "queued"
  | "running"
  | "waiting_for_approval"
  | "waiting_for_user_input"
  | "completed"
  | "failed"
  | "canceled";

export interface TaskSummary {
  id: string;
  workspace_id: string;
  project_id: string | null;
  project_name: string | null;
  title: string;
  description: string | null;
  status: TaskStatus;
  priority: TaskPriority;
  assigned_agent_id: string | null;
  assigned_agent_name: string | null;
  assigned_agent_kind: string | null;
  created_by_member_id: string | null;
  due_at: string | null;
  started_at: string | null;
  completed_at: string | null;
  progress_percent: number;
  requires_approval: boolean;
  tags: string[];
  subtask_count: number;
  subtask_done_count: number;
  comment_count: number;
  inserted_at: string;
  updated_at: string;
}

export interface Subtask {
  id: string;
  task_id: string;
  title: string;
  done: boolean;
  position: number;
}

export interface TaskComment {
  id: string;
  task_id: string;
  author_name: string;
  author_kind: "member" | "agent";
  body: string;
  inserted_at: string;
}

export const TASK_STATUS_LABELS: Record<TaskStatus, string> = {
  to_do: "To Do",
  in_progress: "In Progress",
  in_review: "In Review",
  waiting: "Waiting",
  blocked: "Blocked",
  completed: "Completed",
  canceled: "Canceled",
  overdue: "Overdue",
};

/**
 * The board shows three simple lanes. Statuses collapse into them
 * (`kanbanColumnFor`); dropping a card sets the column's canonical status,
 * which drives the agent (start / stop / celebrate) on the backend.
 */
export type KanbanColumn = "to_do" | "in_progress" | "completed";

export const KANBAN_COLUMNS: KanbanColumn[] = ["to_do", "in_progress", "completed"];

export const KANBAN_COLUMN_LABELS: Record<KanbanColumn, string> = {
  to_do: "To Do",
  in_progress: "In Progress",
  completed: "Done",
};

export function kanbanColumnFor(status: TaskStatus): KanbanColumn {
  switch (status) {
    case "in_progress":
    case "waiting":
      return "in_progress";
    case "in_review":
    case "completed":
      return "completed";
    default:
      // to_do, blocked, canceled, overdue — work not currently running.
      return "to_do";
  }
}
