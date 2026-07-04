export type MemberStatus = "active" | "invited" | "suspended" | "removed";

export type LeaveType = "vacation" | "sick_leave" | "remote_work" | "other";

export type LeaveStatus = "pending" | "approved" | "rejected" | "canceled";

export interface MemberSummary {
  id: string;
  workspace_id: string;
  user_id: string;
  full_name: string;
  email: string;
  avatar_url: string | null;
  role_name: string;
  team_name: string | null;
  title: string | null;
  status: MemberStatus;
  linked_agent_id: string | null;
  linked_agent_name: string | null;
  mfa_enabled: boolean;
  joined_at: string | null;
  last_active_at: string | null;
}

export interface LeaveRequestSummary {
  id: string;
  workspace_id: string;
  member_id: string;
  member_name: string;
  agent_id: string | null;
  type: LeaveType;
  status: LeaveStatus;
  start_at: string;
  end_at: string;
  reason: string | null;
  reviewed_by_name: string | null;
  reviewed_at: string | null;
  inserted_at: string;
}

export const ROLE_NAMES = [
  "Owner",
  "Admin",
  "Manager",
  "Member",
  "Viewer",
  "Agent User",
  "Billing Admin",
] as const;

export type RoleName = (typeof ROLE_NAMES)[number];
