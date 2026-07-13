/** Agent domain contracts shared between web app, 3D layer and realtime events. */

export type AgentKind = "ai" | "human_linked" | "hybrid";

export type AgentStatus =
  | "active"
  | "busy"
  | "idle"
  | "waiting"
  | "blocked"
  | "away"
  | "offline"
  | "archived";

export type PresenceStatus = "online" | "offline" | "away";

/** Visual/animation states of the 3D avatar. Mapped from backend statuses. */
export type AgentVisualState =
  | "idle"
  | "walking"
  | "working"
  | "typing"
  | "thinking"
  | "talking"
  | "waiting"
  | "blocked"
  | "celebrating"
  | "away"
  | "offline"
  | "reviewing"
  | "learning"
  | "requesting_approval";

export type ControlMode =
  | "ai_controlled"
  | "human_controlled"
  | "shared_control"
  | "waiting_for_takeover";

export interface AgentSummary {
  id: string;
  workspace_id: string;
  kind: AgentKind;
  display_name: string;
  slug: string;
  role_title: string | null;
  department: string | null;
  status: AgentStatus;
  presence_status: PresenceStatus;
  linked_user_id: string | null;
  linked_member_id: string | null;
  linked_user_name: string | null;
  ai_enabled: boolean;
  human_takeover_enabled: boolean;
  avatar_config: AvatarConfig;
  avatar_asset_id: string | null;
  current_task_id: string | null;
  current_task_title: string | null;
  performance_score: number | null;
  skills: AgentSkill[];
  tasks_in_progress: number;
  projects_count: number;
  last_active_at: string | null;
  inserted_at: string;
}

export interface AgentSkill {
  name: string;
  level: number; // 0..100
}

export interface AvatarConfig {
  preset: string;
  primary_color: string;
  accent_color: string;
  seat_index?: number;
}

/** Maps a backend agent/task status to a 3D visual state. */
export function toVisualState(
  status: AgentStatus,
  presence: PresenceStatus,
  extra?: { waiting_approval?: boolean; celebrating?: boolean; has_task?: boolean },
): AgentVisualState {
  if (extra?.celebrating) return "celebrating";
  if (extra?.waiting_approval) return "requesting_approval";
  switch (status) {
    case "busy":
      // At the desk executing a run — "working", not mere typing.
      return extra?.has_task ? "working" : "typing";
    case "active":
      // At the desk when on a task; free to roam the office otherwise.
      return extra?.has_task ? "working" : "idle";
    case "waiting":
      // Waiting on a human decision — stays at the desk, not wandering.
      return "waiting";
    case "blocked":
      return "blocked";
    case "away":
      return "away";
    case "offline":
    case "archived":
      return "offline";
    case "idle":
      return presence === "online" ? "idle" : "offline";
    default:
      return presence === "online" ? "idle" : "offline";
  }
}
