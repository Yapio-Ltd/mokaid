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
  workspaces_total: number;
  mrr_cents: number;
  subscriptions_active: number;
  subscriptions_past_due: number;
  invoices_pending: number;
  new_users_30d: number;
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
};

export type CreditTxn = {
  id: string;
  workspace_id: string;
  kind: string;
  amount: number;
  cost_cents?: number;
  balance_after?: number;
  description?: string | null;
  inserted_at: string;
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
