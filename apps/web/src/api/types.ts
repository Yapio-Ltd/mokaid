import type {
  AgentKind,
  AgentStatus,
  AvatarConfig,
  AgentSkill,
  PresenceStatus,
  TaskPriority,
  TaskStatus,
  ProjectStatus,
  LeaveStatus,
  LeaveType,
  MemberStatus,
  DriveItemKind,
  DriveVisibility,
  DriveItemStatus,
} from "@mokaid/shared-types";

export interface Envelope<T> {
  data: T;
  meta?: Record<string, unknown>;
}

export interface AgentLearning {
  missions_total: number;
  domain_counts: Record<string, number>;
  specialty: string | null;
  specialized_at: string | null;
}

export interface AgentCapabilities {
  learning?: AgentLearning;
  [key: string]: unknown;
}

export interface Agent {
  id: string;
  workspace_id: string;
  kind: AgentKind;
  display_name: string;
  slug: string;
  email_alias: string | null;
  avatar_config: Partial<AvatarConfig>;
  role_title: string | null;
  department: string | null;
  status: AgentStatus;
  presence_status: PresenceStatus;
  control_mode: string;
  ai_enabled: boolean;
  human_takeover_enabled: boolean;
  skills: AgentSkill[];
  capabilities: AgentCapabilities | null;
  current_task_id: string | null;
  performance_score: number | null;
  /** Gamified progression: XP ring around the avatar, level badge. */
  level: number;
  xp: number;
  xp_for_next_level: number;
  missions_completed: number;
  linked_user_id: string | null;
  linked_member_id: string | null;
  linked_user_name: string | null;
  linked_user_email: string | null;
  last_active_at: string | null;
  inserted_at: string;
}

export interface AgentProgression {
  level: number;
  xp: number;
  xp_for_next_level: number;
  missions_completed: number;
  performance_score: number | null;
  specialty: string | null;
  recent_memories: Array<{ id: string; title: string; inserted_at: string }>;
}

export interface AgentCounts {
  total: number;
  ai: number;
  human_linked: number;
  hybrid: number;
  active: number;
  offline: number;
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
  body: string;
  author_kind: "member" | "agent";
  author_name: string | null;
  inserted_at: string;
}

export interface TaskAttachment {
  id: string;
  name: string;
  mime_type: string | null;
  extension: string | null;
  size_bytes: number | null;
  source: "input" | "output";
  inserted_at: string;
}

export interface TaskRunToolCall {
  tool: string;
  input?: Record<string, unknown>;
  output?: Record<string, unknown> | null;
  risk?: string;
  approved?: boolean | null;
}

export interface TaskRun {
  id: string;
  status: string;
  error: string | null;
  output: {
    steps?: number;
    tool_calls?: TaskRunToolCall[];
    artifacts?: string[];
    summary?: string;
    consultations?: Array<{ colleague: string; question: string }>;
  } | null;
  /** Deep-agent live plan (todo checklist), streamed while the run works. */
  plan?: Array<{ content: string; status: string }>;
  token_usage: Record<string, number> | null;
  started_at: string | null;
  completed_at: string | null;
  inserted_at: string;
}

export interface TaskPendingApproval {
  id: string;
  run_id: string | null;
  tool_name: string;
  risk_level: "low" | "medium" | "high" | "critical";
  proposed_action: string;
  input_payload: Record<string, unknown>;
  inserted_at: string;
}

export interface Task {
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
  assigned_agent_kind: AgentKind | null;
  due_at: string | null;
  started_at: string | null;
  completed_at: string | null;
  progress_percent: number;
  requires_approval: boolean;
  tags: string[];
  position: number;
  subtask_count: number;
  subtask_done_count: number;
  subtasks: Subtask[];
  comments: TaskComment[];
  attachments: TaskAttachment[];
  latest_run: TaskRun | null;
  /** Present on the task detail endpoint when an agent is waiting on a human decision. */
  pending_approval: TaskPendingApproval | null;
  inserted_at: string;
  updated_at: string;
}

export interface ProjectMemberEntry {
  member_id: string;
  role: string;
  full_name: string | null;
  avatar_url: string | null;
}

export interface Project {
  id: string;
  workspace_id: string;
  name: string;
  description: string | null;
  status: ProjectStatus;
  priority: TaskPriority;
  progress_percent: number;
  owner_member_id: string | null;
  owner_name: string | null;
  start_at: string | null;
  due_at: string | null;
  cover_kind: string | null;
  drive_folder_id: string | null;
  task_count: number;
  completed_task_count: number;
  agent_ids: string[];
  members: ProjectMemberEntry[];
  inserted_at: string;
}

export interface ProjectActivity {
  id: string;
  project_id: string;
  actor_type: string;
  actor_name: string | null;
  event_type: string;
  metadata: Record<string, unknown>;
  occurred_at: string;
}

export interface Member {
  id: string;
  workspace_id: string;
  user_id: string;
  full_name: string | null;
  email: string | null;
  avatar_url: string | null;
  role_name: string;
  team_name: string | null;
  title: string | null;
  status: MemberStatus;
  linked_agent_id: string | null;
  linked_agent_name: string | null;
  mfa_enabled: boolean;
  leave_balances: Record<string, number>;
  joined_at: string | null;
  last_active_at: string | null;
}

export interface LeaveRequest {
  id: string;
  member_id: string;
  member_name: string | null;
  agent_id: string | null;
  type: LeaveType;
  status: LeaveStatus;
  start_at: string;
  end_at: string;
  reason: string | null;
  reviewed_by_name: string | null;
  reviewed_at: string | null;
  review_note: string | null;
  inserted_at: string;
}

export interface KnowledgeItem {
  id: string;
  category_id: string | null;
  category_name: string | null;
  category_color: string | null;
  title: string;
  type: "document" | "link" | "file" | "note";
  source_url: string | null;
  status: "draft" | "processing" | "published" | "archived" | "failed";
  visibility: string;
  tags: string[];
  version: number;
  indexing_status: string;
  used_by_agent_ids: string[];
  file_size_bytes: number | null;
  created_by_name: string | null;
  updated_at: string;
  inserted_at: string;
}

export interface KnowledgeCategory {
  id: string;
  name: string;
  color: string | null;
  position: number;
  item_count: number;
}

export interface DriveItem {
  id: string;
  parent_id: string | null;
  kind: DriveItemKind;
  name: string;
  mime_type: string | null;
  extension: string | null;
  size_bytes: number | null;
  visibility: DriveVisibility;
  status: DriveItemStatus;
  is_ai_readable: boolean;
  is_system_folder: boolean;
  tags: string[];
  linked_project_id: string | null;
  linked_task_id: string | null;
  linked_agent_id: string | null;
  created_by_kind: "member" | "agent";
  created_by_name: string | null;
  version_count: number;
  trashed_at: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface CalendarEvent {
  id: string;
  title: string;
  description: string | null;
  kind: string;
  start_at: string;
  end_at: string | null;
  all_day: boolean;
  member_id: string | null;
  member_name: string | null;
  agent_id: string | null;
  agent_name: string | null;
  project_id: string | null;
  project_name: string | null;
  task_id: string | null;
  task_title: string | null;
  color: string | null;
}

export interface IntegrationProvider {
  id: string;
  key: string;
  name: string;
  category: string;
  description: string | null;
  auth_kind: string;
  icon_slug: string | null;
  logo_url: string | null;
}

export interface IntegrationConnection {
  id: string;
  provider_key: string;
  provider_name: string;
  category: string;
  description: string | null;
  status: "connected" | "disconnected" | "error" | "pending";
  connected_account: string | null;
  permissions: Record<string, unknown>;
  last_sync_at: string | null;
}

export interface McpServer {
  id: string;
  key: string;
  name: string;
  category: string;
  description: string | null;
  logo_slug: string | null;
  logo_url: string | null;
  featured: boolean;
  auth_kind: "oauth2" | "api_key" | "none" | "custom";
  transport: string;
  server_url: string | null;
  docs_url: string | null;
}

export interface McpInstallation {
  id: string;
  server_id: string;
  server_key: string;
  server_name: string;
  category: string;
  logo_slug: string | null;
  logo_url: string | null;
  auth_kind: string;
  status: "pending" | "connected" | "error" | "disconnected";
  connected_account: string | null;
  settings: { server_url?: string };
  error: string | null;
  last_used_at: string | null;
  inserted_at: string;
}

export interface McpGrant {
  id: string;
  agent_id: string;
  installation_id: string;
  granted: boolean;
  server_key: string;
  server_name: string;
  logo_slug: string | null;
  logo_url: string | null;
}

export interface BillingOverview {
  subscription: {
    id: string;
    status: string;
    billing_cycle: string;
    current_period_start: string | null;
    current_period_end: string | null;
    payment_method: { brand?: string; last4?: string; exp?: string };
    credits_balance: number;
    plan: {
      key: string;
      name: string;
      price_cents_monthly: number;
      price_cents_yearly: number;
      limits: Record<string, number>;
      features: string[];
    } | null;
  } | null;
  usage: Array<{
    event_type: string;
    unit: string;
    total_quantity: string;
    total_cost_cents: number;
  }>;
  daily_usage: Array<{ day: string; event_type: string; total: string }>;
  credits: CreditsSummary;
  credit_transactions: CreditTransaction[];
}

export interface CreditsSummary {
  included_remaining: number;
  balance: number;
  spendable: number;
  monthly_credits: number;
  unlimited: boolean;
  auto_recharge_enabled?: boolean;
  auto_recharge_pack_key?: string | null;
  auto_recharge_threshold?: number;
}

export interface CreditTransaction {
  id: string;
  kind: "spend" | "plan_grant" | "purchase" | "auto_recharge" | "adjustment";
  amount: number;
  cost_cents: number;
  balance_after: number;
  description: string | null;
  inserted_at: string;
}

export interface CreditPack {
  key: string;
  credits: number;
  price_cents: number;
}

/** Either an immediate activation (free plan / dev) or a hosted checkout URL. */
export interface CheckoutResult {
  activated?: boolean;
  simulated?: boolean;
  credits?: number;
  sale_url?: string;
  invoice_id?: string;
  subscription?: BillingOverview["subscription"];
}

export interface Invoice {
  id: string;
  number: string;
  status: string;
  amount_cents: number;
  currency: string;
  issued_at: string | null;
  paid_at: string | null;
  line_items: Array<{ description: string; amount_cents: number }>;
}

export interface AnalyticsOverview {
  overview: {
    total_tasks: number;
    completed_tasks: number;
    completion_rate: number;
    in_progress: number;
    overdue: number;
    active_agents: number;
    avg_task_hours: number;
  };
  tasks_by_status: Array<{ status: string; count: number }>;
  tasks_by_priority: Array<{ priority: string; count: number }>;
  tasks_completed_daily: Array<{ day: string; count: number }>;
  top_agents: Array<{
    agent_id: string;
    display_name: string;
    role_title: string | null;
    kind: string;
    performance_score: number | null;
    tasks_done: number;
  }>;
  agent_task_split: Array<{ kind: string; count: number }>;
}

export interface Workspace {
  id: string;
  name: string;
  slug: string;
  logo_url: string | null;
  has_logo?: boolean;
  description: string | null;
  industry: string | null;
  timezone: string;
  date_format: string;
  time_format: string;
  language: string;
  default_landing_page: string;
  feature_toggles: Record<string, boolean>;
  settings: Record<string, unknown> | null;
  inserted_at: string;
}

/** Onboarding progress persisted in workspace.settings.onboarding */
export interface OnboardingSettings {
  wizard_done?: boolean;
  tour_done?: boolean;
  checklist_dismissed?: boolean;
}

/* ---------- Intelligent dispatch (3D drop / quick task) ---------- */

export interface DispatchFileInput {
  drive_item_id: string;
  name: string;
  mime_type: string | null;
  size_bytes: number | null;
}

export interface DispatchCustomAgent {
  display_name: string;
  role_title: string | null;
  department: string | null;
  skills: Array<{ name: string; level: number }>;
}

export interface DispatchAlternative {
  agent_id: string;
  confidence: number;
  reason: string;
}

export interface DispatchMcpSuggestion {
  server_key: string;
  server_name: string;
  auth_kind: "oauth2" | "api_key" | "none" | "custom";
  logo_slug: string | null;
  reason: string;
  status: "ready" | "needs_grant" | "not_installed";
  installation_id: string | null;
}

export interface DispatchAnalysis {
  task: { title: string; description: string; priority: TaskPriority };
  recommendation: {
    mode: "existing_agent" | "custom_agent" | "user_choice";
    agent_id: string | null;
    confidence: number;
    reason: string;
    alternatives: DispatchAlternative[];
    custom_agent: DispatchCustomAgent | null;
  };
  mcp_suggestions: DispatchMcpSuggestion[];
}

export interface DispatchConfirmResult {
  task: Task;
  agent: Agent | null;
  run_id: string | null;
}

/* ---------- Agent direct chat (floating dock) ---------- */

export interface ChatAttachment {
  drive_item_id: string;
  name: string | null;
  mime_type: string | null;
  size_bytes: number | null;
}

export interface AgentChatMessage {
  id: string;
  agent_id: string;
  body: string;
  author_kind: "member" | "agent";
  author_name: string | null;
  attachments: ChatAttachment[];
  task_id: string | null;
  inserted_at: string;
}

export interface AgentChatSummary {
  agent_id: string;
  unread_count: number;
  last_message: AgentChatMessage;
}

export interface AppNotification {
  id: string;
  kind: string;
  title: string;
  body: string | null;
  resource_type: string | null;
  resource_id: string | null;
  read_at: string | null;
  inserted_at: string;
}
