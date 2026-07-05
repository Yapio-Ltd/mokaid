import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiFetch, apiUpload } from "./client";
import type {
  Agent,
  AgentCounts,
  AnalyticsOverview,
  AppNotification,
  BillingOverview,
  CalendarEvent,
  DriveItem,
  Envelope,
  IntegrationConnection,
  IntegrationProvider,
  Invoice,
  KnowledgeCategory,
  KnowledgeItem,
  LeaveRequest,
  McpGrant,
  McpInstallation,
  McpServer,
  Member,
  Project,
  ProjectActivity,
  Task,
  TaskComment,
  Workspace,
} from "./types";
import { useAuthStore } from "@/stores/auth-store";

function useWorkspaceKey(base: string): (string | null)[] {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return [base, workspaceId];
}

/* ---------- Agents ---------- */

export function useAgents(filters: Record<string, string | undefined> = {}) {
  const key = useWorkspaceKey("agents");
  return useQuery({
    queryKey: [...key, filters],
    queryFn: () =>
      apiFetch<{ data: Agent[]; meta: { counts: AgentCounts } }>("/api/agents", {
        params: filters,
      }),
  });
}

export function useAgent(id: string | null) {
  const key = useWorkspaceKey("agents");
  return useQuery({
    queryKey: [...key, "detail", id],
    enabled: id != null,
    queryFn: () => apiFetch<Envelope<Agent>>(`/api/agents/${id}`),
  });
}

export function useCreateAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: Partial<Agent> & { kind: string; display_name: string }) =>
      apiFetch<Envelope<Agent>>("/api/agents", { method: "POST", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["agents"] }),
  });
}

export function useUpdateAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: Partial<Agent> & { id: string }) =>
      apiFetch<Envelope<Agent>>(`/api/agents/${id}`, { method: "PATCH", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["agents"] }),
  });
}

/* ---------- Tasks ---------- */

export function useTasks(filters: Record<string, string | undefined> = {}) {
  const key = useWorkspaceKey("tasks");
  return useQuery({
    queryKey: [...key, filters],
    queryFn: () =>
      apiFetch<{
        data: Task[];
        meta: { counts: Record<string, number>; completed_today: number };
      }>("/api/tasks", { params: filters }),
  });
}

export function useTask(id: string | null) {
  const key = useWorkspaceKey("tasks");
  return useQuery({
    queryKey: [...key, "detail", id],
    enabled: id != null,
    queryFn: () => apiFetch<Envelope<Task>>(`/api/tasks/${id}`),
  });
}

export function useCreateTask() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: Partial<Task> & { title: string }) =>
      apiFetch<Envelope<Task>>("/api/tasks", { method: "POST", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["tasks"] }),
  });
}

export function useUpdateTask() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: Partial<Task> & { id: string }) =>
      apiFetch<Envelope<Task>>(`/api/tasks/${id}`, { method: "PATCH", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["tasks"] }),
  });
}

export function useCreateTaskComment() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ taskId, body }: { taskId: string; body: string }) =>
      apiFetch<Envelope<TaskComment>>(`/api/tasks/${taskId}/comments`, {
        method: "POST",
        body: { body },
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["tasks"] }),
  });
}

export function useToggleSubtask() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ taskId, subtaskId, done }: { taskId: string; subtaskId: string; done: boolean }) =>
      apiFetch<Envelope<{ id: string; done: boolean }>>(
        `/api/tasks/${taskId}/subtasks/${subtaskId}`,
        { method: "PATCH", body: { done } },
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["tasks"] }),
  });
}

export function useExecuteAi() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ taskId, input }: { taskId: string; input?: Record<string, unknown> }) =>
      apiFetch<Envelope<{ run_id: string; status: string }>>(`/api/tasks/${taskId}/execute-ai`, {
        method: "POST",
        body: { input },
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["tasks"] }),
  });
}

/* ---------- Projects ---------- */

export function useProjects(filters: Record<string, string | undefined> = {}) {
  const key = useWorkspaceKey("projects");
  return useQuery({
    queryKey: [...key, filters],
    queryFn: () =>
      apiFetch<{
        data: Project[];
        meta: { counts: Record<string, number>; activity: ProjectActivity[] };
      }>("/api/projects", { params: filters }),
  });
}

export function useCreateProject() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: Partial<Project> & { name: string }) =>
      apiFetch<Envelope<Project>>("/api/projects", { method: "POST", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["projects"] }),
  });
}

export function useUpdateProject() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: Partial<Project> & { id: string }) =>
      apiFetch<Envelope<Project>>(`/api/projects/${id}`, { method: "PATCH", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["projects"] }),
  });
}

/* ---------- Knowledge ---------- */

export function useKnowledgeItems(filters: Record<string, string | undefined> = {}) {
  const key = useWorkspaceKey("knowledge");
  return useQuery({
    queryKey: [...key, filters],
    queryFn: () =>
      apiFetch<{ data: KnowledgeItem[]; meta: { counts: Record<string, number> } }>(
        "/api/knowledge",
        { params: filters },
      ),
  });
}

export function useKnowledgeCategories() {
  const key = useWorkspaceKey("knowledge");
  return useQuery({
    queryKey: [...key, "categories"],
    queryFn: () => apiFetch<Envelope<KnowledgeCategory[]>>("/api/knowledge-categories"),
  });
}

export function useCreateKnowledge() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      title: string;
      type: string;
      body?: string;
      source_url?: string;
      category_id?: string;
      tags?: string[];
      status?: string;
    }) => apiFetch<Envelope<KnowledgeItem>>("/api/knowledge", { method: "POST", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["knowledge"] }),
  });
}

/* ---------- Drive ---------- */

export function useDriveItems(parentId: string | null) {
  const key = useWorkspaceKey("drive");
  return useQuery({
    queryKey: [...key, parentId],
    queryFn: () =>
      apiFetch<Envelope<DriveItem[]>>("/api/drive", {
        params: { parent_id: parentId ?? undefined },
      }),
  });
}

export function useDriveTrash() {
  const key = useWorkspaceKey("drive");
  return useQuery({
    queryKey: [...key, "trash"],
    queryFn: () => apiFetch<Envelope<DriveItem[]>>("/api/drive-trash"),
  });
}

export function useCreateFolder() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { name: string; parent_id?: string | null }) =>
      apiFetch<Envelope<DriveItem>>("/api/drive", {
        method: "POST",
        body: { ...body, kind: "folder" },
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["drive"] }),
  });
}

export function useTrashDriveItem() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => apiFetch<Envelope<DriveItem>>(`/api/drive/${id}`, { method: "DELETE" }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["drive"] }),
  });
}

export function useUploadDriveFile() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ file, parentId }: { file: File; parentId: string | null }) => {
      const formData = new FormData();
      formData.append("file", file);
      if (parentId) formData.append("parent_id", parentId);
      return apiUpload<Envelope<DriveItem>>("/api/drive/upload", formData);
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["drive"] }),
  });
}

export function useRestoreDriveItem() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<Envelope<DriveItem>>(`/api/drive/${id}/restore`, { method: "POST" }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["drive"] }),
  });
}

/* ---------- Calendar ---------- */

export function useCalendarEvents(filters: Record<string, string | undefined> = {}) {
  const key = useWorkspaceKey("calendar");
  return useQuery({
    queryKey: [...key, filters],
    queryFn: () =>
      apiFetch<Envelope<CalendarEvent[]>>("/api/calendar/events", { params: filters }),
  });
}

export function useCreateCalendarEvent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      title: string;
      kind?: string;
      description?: string;
      start_at: string;
      end_at?: string;
      all_day?: boolean;
      project_id?: string;
    }) =>
      apiFetch<Envelope<{ id: string; title: string }>>("/api/calendar/events", {
        method: "POST",
        body,
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["calendar"] }),
  });
}

/* ---------- Members & leave ---------- */

export function useMembers() {
  const key = useWorkspaceKey("members");
  return useQuery({
    queryKey: key,
    queryFn: () =>
      apiFetch<{
        data: Member[];
        meta: { pending_invites: Array<{ id: string; email: string; expires_at: string }> };
      }>("/api/members"),
  });
}

export function useInviteMember() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { email: string; role_id?: string }) =>
      apiFetch<Envelope<{ id: string; email: string }>>("/api/members/invite", {
        method: "POST",
        body,
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["members"] }),
  });
}

export function useUpdateMember() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      id,
      ...body
    }: {
      id: string;
      title?: string;
      status?: string;
      role_id?: string;
      team_id?: string;
    }) => apiFetch<Envelope<Member>>(`/api/members/${id}`, { method: "PATCH", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["members"] }),
  });
}

export function useLinkMemberAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ memberId, agentId }: { memberId: string; agentId: string }) =>
      apiFetch<Envelope<Agent>>(`/api/members/${memberId}/link-agent`, {
        method: "POST",
        body: { agent_id: agentId },
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["members"] });
      queryClient.invalidateQueries({ queryKey: ["agents"] });
    },
  });
}

export function useLeaveRequests() {
  const key = useWorkspaceKey("leave-requests");
  return useQuery({
    queryKey: key,
    queryFn: () => apiFetch<Envelope<LeaveRequest[]>>("/api/leave-requests"),
  });
}

export function useCreateLeaveRequest() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { type: string; start_at: string; end_at: string; reason?: string }) =>
      apiFetch<Envelope<LeaveRequest>>("/api/leave-requests", { method: "POST", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["leave-requests"] }),
  });
}

export function useReviewLeaveRequest() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, decision, note }: { id: string; decision: "approve" | "reject"; note?: string }) =>
      apiFetch<Envelope<LeaveRequest>>(`/api/leave-requests/${id}/${decision}`, {
        method: "POST",
        body: { note },
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["leave-requests"] }),
  });
}

/* ---------- Integrations ---------- */

export function useIntegrations() {
  const key = useWorkspaceKey("integrations");
  return useQuery({
    queryKey: key,
    queryFn: () =>
      apiFetch<
        Envelope<{ providers: IntegrationProvider[]; connections: IntegrationConnection[] }>
      >("/api/integrations"),
  });
}

export function useConnectIntegration() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (providerKey: string) =>
      apiFetch<Envelope<IntegrationConnection>>(`/api/integrations/${providerKey}/connect`, {
        method: "POST",
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["integrations"] }),
  });
}

export function useDisconnectIntegration() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (connectionId: string) =>
      apiFetch<Envelope<IntegrationConnection>>(`/api/integrations/${connectionId}/disconnect`, {
        method: "POST",
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["integrations"] }),
  });
}

/* ---------- MCP Hub ---------- */

export function useMcpHub() {
  const key = useWorkspaceKey("mcp");
  return useQuery({
    queryKey: key,
    queryFn: () =>
      apiFetch<Envelope<{ servers: McpServer[]; installations: McpInstallation[] }>>("/api/mcp"),
  });
}

export function useInstallMcp() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      serverKey,
      ...body
    }: {
      serverKey: string;
      credentials?: Record<string, string>;
      server_url?: string;
      connected_account?: string;
    }) =>
      apiFetch<Envelope<McpInstallation>>(`/api/mcp/${serverKey}/install`, {
        method: "POST",
        body,
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mcp"] }),
  });
}

export function useUninstallMcp() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (installationId: string) =>
      apiFetch<Envelope<{ id: string }>>(`/api/mcp/installations/${installationId}`, {
        method: "DELETE",
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["mcp"] });
      queryClient.invalidateQueries({ queryKey: ["mcp-grants"] });
    },
  });
}

export function useAgentMcpGrants(agentId: string | null) {
  return useQuery({
    queryKey: ["mcp-grants", agentId],
    enabled: agentId != null,
    queryFn: () => apiFetch<Envelope<McpGrant[]>>(`/api/agents/${agentId}/mcp-grants`),
  });
}

export function useSetMcpGrant() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      agentId,
      installationId,
      granted,
    }: {
      agentId: string;
      installationId: string;
      granted: boolean;
    }) =>
      apiFetch<Envelope<McpGrant>>(`/api/agents/${agentId}/mcp-grants/${installationId}`, {
        method: "PUT",
        body: { granted },
      }),
    onSuccess: (_data, { agentId }) =>
      queryClient.invalidateQueries({ queryKey: ["mcp-grants", agentId] }),
  });
}

export function useFigmaOauthStart() {
  return useMutation({
    mutationFn: (redirectUri: string) =>
      apiFetch<Envelope<{ authorize_url: string }>>("/api/mcp/figma/oauth/start", {
        method: "POST",
        body: { redirect_uri: redirectUri },
      }),
  });
}

export function useFigmaOauthCallback() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { code: string; state: string; redirect_uri: string }) =>
      apiFetch<Envelope<McpInstallation>>("/api/mcp/figma/oauth/callback", {
        method: "POST",
        body,
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mcp"] }),
  });
}

/* ---------- Billing & analytics ---------- */

export function useBillingOverview() {
  const key = useWorkspaceKey("billing");
  return useQuery({
    queryKey: [...key, "overview"],
    queryFn: () => apiFetch<Envelope<BillingOverview>>("/api/billing/overview"),
  });
}

export function useInvoices() {
  const key = useWorkspaceKey("billing");
  return useQuery({
    queryKey: [...key, "invoices"],
    queryFn: () => apiFetch<Envelope<Invoice[]>>("/api/billing/invoices"),
  });
}

export interface BillingPlanSummary {
  key: string;
  name: string;
  price_cents_monthly: number;
  price_cents_yearly: number;
  limits: Record<string, number>;
  features: string[];
}

export function useBillingPlans() {
  const key = useWorkspaceKey("billing");
  return useQuery({
    queryKey: [...key, "plans"],
    queryFn: () => apiFetch<Envelope<BillingPlanSummary[]>>("/api/billing/plans"),
  });
}

export function useChangePlan() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { plan_key: string; billing_cycle?: string }) =>
      apiFetch<Envelope<unknown>>("/api/billing/change-plan", { method: "POST", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["billing"] }),
  });
}

export function useAnalyticsOverview() {
  const key = useWorkspaceKey("analytics");
  return useQuery({
    queryKey: [...key, "overview"],
    queryFn: () => apiFetch<Envelope<AnalyticsOverview>>("/api/analytics/overview"),
  });
}

/* ---------- Workspace & notifications ---------- */

export function useWorkspace() {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useQuery({
    queryKey: ["workspace", workspaceId],
    enabled: workspaceId != null,
    queryFn: () => apiFetch<Envelope<Workspace>>(`/api/workspaces/${workspaceId}`),
  });
}

export function useUpdateWorkspace() {
  const queryClient = useQueryClient();
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useMutation({
    mutationFn: (body: Partial<Workspace>) =>
      apiFetch<Envelope<Workspace>>(`/api/workspaces/${workspaceId}`, { method: "PATCH", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["workspace"] }),
  });
}

export function useNotifications() {
  const key = useWorkspaceKey("notifications");
  return useQuery({
    queryKey: key,
    queryFn: () => apiFetch<Envelope<AppNotification[]>>("/api/notifications"),
    refetchInterval: 30_000,
  });
}

export function useMarkNotificationRead() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<Envelope<AppNotification>>(`/api/notifications/${id}/read`, { method: "POST" }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["notifications"] }),
  });
}
