export type ProjectStatus =
  | "planning"
  | "active"
  | "in_review"
  | "on_hold"
  | "completed"
  | "archived";

export interface ProjectSummary {
  id: string;
  workspace_id: string;
  name: string;
  description: string | null;
  status: ProjectStatus;
  priority: "low" | "medium" | "high" | "urgent";
  progress_percent: number;
  owner_member_id: string | null;
  owner_name: string | null;
  start_at: string | null;
  due_at: string | null;
  task_count: number;
  completed_task_count: number;
  agent_ids: string[];
  cover_kind: string | null;
  inserted_at: string;
}

export const PROJECT_STATUS_LABELS: Record<ProjectStatus, string> = {
  planning: "Planning",
  active: "Active",
  in_review: "In Review",
  on_hold: "On Hold",
  completed: "Completed",
  archived: "Archived",
};
