export type AdminUser = {
  id: string;
  email: string;
  full_name: string;
  status?: string | null;
  locale?: string;
  timezone?: string;
  is_platform_admin?: boolean;
  mfa_enabled?: boolean;
  last_login_at?: string | null;
  auth_provider?: string;
  has_password?: boolean;
  inserted_at?: string;
  banned_at?: string | null;
  ban_reason?: string | null;
  ban_expires_at?: string | null;
  deletion_scheduled_at?: string | null;
  anonymized_at?: string | null;
  operator_notes?: string | null;
  memberships?: Array<{
    id: string;
    workspace_id: string;
    workspace_name?: string;
    workspace_slug?: string;
    role_name?: string;
    status?: string;
    title?: string | null;
  }>;
};

export type PageMeta = {
  page: number;
  per_page: number;
  total: number;
  total_pages: number;
};

export type Metrics = {
  users_total: number;
  users_active: number;
  users_banned?: number;
  workspaces_total: number;
  mrr_cents: number;
  arr_cents?: number;
  arpu_cents?: number;
  subscriptions_active: number;
  subscriptions_past_due: number;
  invoices_pending: number;
  new_users_30d: number;
  credits_spend_30d?: number;
  credits_balance_total?: number;
  internal_ai_cost_mtd_cents?: number;
  provider_cost_mtd_cents?: number;
  openai_cost_mtd_cents?: number;
  anthropic_cost_mtd_cents?: number;
  aws_cost_mtd_cents?: number;
  gross_margin_cents?: number;
  deletions_pending?: number;
};

export type MetricsTimeseries = {
  days: number;
  new_users: Array<{ day: string; count: number }>;
  usage: Array<{ day: string; cost_cents: number; events: number }>;
  provider_costs: Array<{ day: string; provider: string; amount_cents: number }>;
  credits_spend: Array<{ day: string; credits: number; cost_cents: number }>;
};

export type CostSummary = {
  mrr_cents: number;
  internal_ai_cost_mtd_cents: number;
  provider_cost_mtd_cents: number;
  openai_cost_mtd_cents: number;
  anthropic_cost_mtd_cents: number;
  aws_cost_mtd_cents: number;
  gross_margin_cents: number;
  window_totals_cents: Record<string, number>;
  window_total_cents: number;
  days: number;
  reconciliation: CostReconciliation[];
};

export type CostSnapshot = {
  id: string;
  provider: string;
  granularity: string;
  period_start: string;
  period_end: string;
  amount_cents: number;
  currency: string;
  breakdown: Record<string, unknown>;
  source: string;
  fetched_at: string;
};

export type CostReconciliation = {
  id: string;
  day: string;
  provider: string;
  provider_reported_cents: number;
  internal_usage_cents: number;
  delta_cents: number;
  notes?: string | null;
};

export type CostListResponse = {
  days: number;
  totals_cents: Record<string, number>;
  total_cents: number;
  snapshots: CostSnapshot[];
  reconciliation: CostReconciliation[];
};

export type UnifiedLog = {
  id: string;
  source: string;
  occurred_at: string;
  actor?: string | null;
  action: string;
  resource_type?: string | null;
  resource_id?: string | null;
  workspace_id?: string | null;
  message?: string;
  ip_address?: string | null;
  metadata?: Record<string, unknown>;
};

export type LoginEvent = {
  id: string;
  ip_address?: string | null;
  user_agent?: string | null;
  auth_method: string;
  success: boolean;
  occurred_at: string;
};

export type UserSummary = {
  user: AdminUser;
  logins: LoginEvent[];
  credit_transactions: CreditTxn[];
  usage_events: UsageEvent[];
  invoices: Array<{
    id: string;
    number: string;
    status: string;
    amount_cents: number;
    workspace_name?: string;
    issued_at?: string;
  }>;
  subscriptions: Subscription[];
  usage_cost_30d_cents: number;
  audit_logs: AuditLog[];
};

export type Plan = {
  id: string;
  key: string;
  name: string;
  price_cents_monthly: number;
  price_cents_yearly: number;
  limits: Record<string, unknown>;
  features: string[];
};

export type Subscription = {
  id: string;
  workspace_id: string;
  workspace_name?: string;
  workspace_slug?: string;
  status: string;
  billing_cycle: string;
  current_period_start?: string;
  current_period_end?: string;
  credits_balance: number;
  monthly_credits: number;
  included_credits_remaining: number;
  plan?: Plan | null;
};

export type WorkspaceRow = {
  id: string;
  name: string;
  slug: string;
  description?: string | null;
  industry?: string | null;
  timezone?: string;
  language?: string;
  feature_toggles?: Record<string, unknown>;
  usage_limits?: Record<string, unknown>;
  settings?: Record<string, unknown>;
  member_count?: number;
  subscription?: Subscription | null;
  deleted_at?: string | null;
  inserted_at?: string;
};

export type Invoice = {
  id: string;
  number: string;
  status: string;
  amount_cents: number;
  currency: string;
  issued_at?: string;
  paid_at?: string | null;
  workspace_id?: string;
  workspace_name?: string;
  kind?: string;
  line_items?: unknown[];
};

export type AuditLog = {
  id: string;
  workspace_id?: string | null;
  actor_type: string;
  actor_name?: string | null;
  action: string;
  resource_type?: string | null;
  resource_id?: string | null;
  metadata?: Record<string, unknown>;
  occurred_at: string;
  ip_address?: string | null;
  user_agent?: string | null;
};

export type CreditTxn = {
  id: string;
  workspace_id: string;
  kind: string;
  amount: number;
  cost_cents?: number;
  balance_after?: number;
  description?: string | null;
  reason?: string | null;
  operator_id?: string | null;
  inserted_at: string;
};

export type UsageEvent = {
  id: string;
  workspace_id: string;
  actor_type: string | null;
  actor_id: string | null;
  event_type: string;
  quantity: number | null;
  unit: string | null;
  cost_cents: number | null;
  metadata: Record<string, unknown> | null;
  occurred_at: string;
};

export type MemberRow = {
  id: string;
  workspace_id: string;
  workspace_name?: string;
  user_id?: string;
  full_name?: string;
  email?: string;
  role_name?: string;
  status?: string;
  title?: string | null;
};

export type Invite = {
  id: string;
  email: string;
  status: string;
  workspace_id: string;
  workspace_name?: string;
  role_name?: string;
  expires_at?: string;
  inserted_at?: string;
};
