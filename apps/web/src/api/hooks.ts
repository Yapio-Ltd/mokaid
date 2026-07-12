import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiFetch, apiUpload } from "./client";
import type {
  Agent,
  AgentChatConversation,
  AgentChatMessage,
  AgentChatSummary,
  AgentProgression,
  AgentCounts,
  AnalyticsOverview,
  AppNotification,
  BillingOverview,
  CalendarEvent,
  CheckoutResult,
  CreditPack,
  DispatchAnalysis,
  DispatchConfirmResult,
  DispatchCustomAgent,
  DispatchFileInput,
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
  OnboardingSettings,
  Project,
  ProjectActivity,
  Task,
  TaskComment,
  Workspace,
} from "./types";
import { useAuthStore } from "@/stores/auth-store";

export interface Asset3d {
  id: string;
  slug: string;
  kind: "character" | "environment" | "accessory" | "furniture" | "prop";
  storage_key: string;
  cdn_path: string;
  url: string;
  sha256: string;
  byte_size: number;
  animation_clips: string[];
  metadata: Record<string, unknown>;
  inserted_at: string;
}

function useWorkspaceKey(base: string): (string | null)[] {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return [base, workspaceId];
}

/* ---------- Agents ---------- */

export function useAssets3d(kind?: string) {
  return useQuery({
    queryKey: ["assets-3d", kind ?? "all"],
    queryFn: () =>
      apiFetch<Envelope<Asset3d[]>>("/api/assets-3d", {
        params: kind ? { kind } : undefined,
        skipWorkspace: true,
      }).then((r) => r.data),
  });
}

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

export function useAgentProgression(id: string | null) {
  const key = useWorkspaceKey("agents");
  return useQuery({
    queryKey: [...key, "progression", id],
    enabled: id != null,
    queryFn: () => apiFetch<Envelope<AgentProgression>>(`/api/agents/${id}/progression`),
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

export function useDeleteAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<void>(`/api/agents/${id}`, { method: "DELETE" }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["agents"] }),
  });
}

export function useUploadAgentFiles() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ agentId, files }: { agentId: string; files: File[] }) => {
      const formData = new FormData();
      for (const file of files) formData.append("files", file);
      return apiUpload<Envelope<{ count: number }>>(`/api/agents/${agentId}/files`, formData);
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["agents"] });
      queryClient.invalidateQueries({ queryKey: ["drive"] });
    },
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
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["tasks"] });
      queryClient.invalidateQueries({ queryKey: ["notifications"] });
    },
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

/** Stops the agent's work on the task (aborts the run, task back to To Do). */
export function useStopTaskAi() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (taskId: string) =>
      apiFetch<Envelope<{ id: string; status: string }>>(`/api/tasks/${taskId}/stop-ai`, {
        method: "POST",
        body: {},
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["tasks"] });
      queryClient.invalidateQueries({ queryKey: ["agents"] });
    },
  });
}

export function useDeleteTask() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (taskId: string) =>
      apiFetch<{ ok: boolean }>(`/api/tasks/${taskId}`, { method: "DELETE" }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["tasks"] });
      queryClient.invalidateQueries({ queryKey: ["agents"] });
    },
  });
}

/** Human decision on an agent's pending approval request (approve / reject). */
export function useApproveTaskAction() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      taskId,
      approvalRequestId,
      decision,
    }: {
      taskId: string;
      approvalRequestId: string;
      decision: "approved" | "rejected";
    }) =>
      apiFetch<Envelope<{ id: string; status: string }>>(`/api/tasks/${taskId}/approve-action`, {
        method: "POST",
        body: { approval_request_id: approvalRequestId, decision },
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["tasks"] });
      queryClient.invalidateQueries({ queryKey: ["agents"] });
    },
  });
}

/* ---------- Intelligent dispatch ---------- */

export function useDispatchAnalyze() {
  return useMutation({
    mutationFn: (body: { instruction: string; files?: DispatchFileInput[] }) =>
      apiFetch<Envelope<DispatchAnalysis>>("/api/dispatch/analyze", { method: "POST", body }),
  });
}

export function useDispatchConfirm() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      instruction: string;
      task?: { title?: string; description?: string; priority?: string; project_id?: string };
      agent_id?: string;
      custom_agent?: DispatchCustomAgent;
      grant_installation_ids?: string[];
      drive_item_ids?: string[];
      start_now?: boolean;
    }) => apiFetch<Envelope<DispatchConfirmResult>>("/api/dispatch/confirm", { method: "POST", body }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["tasks"] });
      queryClient.invalidateQueries({ queryKey: ["agents"] });
      queryClient.invalidateQueries({ queryKey: ["drive"] });
    },
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

/** Trashes many items at once; used for bulk selection actions. */
export function useTrashDriveItems() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (ids: string[]) =>
      Promise.all(ids.map((id) => apiFetch<Envelope<DriveItem>>(`/api/drive/${id}`, { method: "DELETE" }))),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["drive"] }),
  });
}

export function useMoveDriveItem() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, parentId }: { id: string; parentId: string | null }) =>
      apiFetch<Envelope<DriveItem>>(`/api/drive/${id}`, {
        method: "PATCH",
        body: { parent_id: parentId },
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["drive"] }),
  });
}

/** Moves many items to the same destination folder at once; used for drag-and-drop and bulk selection actions. */
export function useMoveDriveItems() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ ids, parentId }: { ids: string[]; parentId: string | null }) =>
      Promise.all(
        ids.map((id) =>
          apiFetch<Envelope<DriveItem>>(`/api/drive/${id}`, {
            method: "PATCH",
            body: { parent_id: parentId },
          }),
        ),
      ),
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

/** Uploads a file and links it to a task so the agent can use it on the next run. */
export function useAttachTaskFile() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async ({ file, taskId }: { file: File; taskId: string }) => {
      const formData = new FormData();
      formData.append("file", file);
      formData.append("is_ai_readable", "true");
      const uploaded = await apiUpload<Envelope<DriveItem>>("/api/drive/upload", formData);
      return apiFetch<Envelope<DriveItem>>(`/api/drive/${uploaded.data.id}`, {
        method: "PATCH",
        body: { linked_task_id: taskId, is_ai_readable: true },
      });
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["tasks"] });
      queryClient.invalidateQueries({ queryKey: ["drive"] });
    },
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

export function useGoogleOauthStart() {
  return useMutation({
    mutationFn: (body: { redirect_uri: string; provider_key?: string }) =>
      apiFetch<Envelope<{ authorize_url: string }>>("/api/integrations/google/oauth/start", {
        method: "POST",
        body,
      }),
  });
}

export function useGoogleOauthCallback() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { code: string; state: string; redirect_uri: string }) =>
      apiFetch<
        Envelope<{
          connections: IntegrationConnection[];
          connected_account?: string;
          provider_key: string;
        }>
      >("/api/integrations/google/oauth/callback", {
        method: "POST",
        body,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["integrations"] });
      queryClient.invalidateQueries({ queryKey: ["mcp"] });
    },
  });
}

export function useGithubOauthStart() {
  return useMutation({
    mutationFn: (redirectUri: string) =>
      apiFetch<Envelope<{ authorize_url: string }>>("/api/integrations/github/oauth/start", {
        method: "POST",
        body: { redirect_uri: redirectUri },
      }),
  });
}

export function useGithubOauthCallback() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { code: string; state: string; redirect_uri: string }) =>
      apiFetch<
        Envelope<{
          connection: IntegrationConnection;
          connected_account?: string;
          provider_key: string;
        }>
      >("/api/integrations/github/oauth/callback", {
        method: "POST",
        body,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["integrations"] });
      queryClient.invalidateQueries({ queryKey: ["mcp"] });
    },
  });
}

export function useLinearOauthStart() {
  return useMutation({
    mutationFn: (redirectUri: string) =>
      apiFetch<Envelope<{ authorize_url: string }>>("/api/integrations/linear/oauth/start", {
        method: "POST",
        body: { redirect_uri: redirectUri },
      }),
  });
}

export function useLinearOauthCallback() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { code: string; state: string; redirect_uri: string }) =>
      apiFetch<
        Envelope<{
          connection: IntegrationConnection;
          connected_account?: string;
          provider_key: string;
        }>
      >("/api/integrations/linear/oauth/callback", {
        method: "POST",
        body,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["integrations"] });
      queryClient.invalidateQueries({ queryKey: ["mcp"] });
    },
  });
}

export function useSlackOauthStart() {
  return useMutation({
    mutationFn: (redirectUri: string) =>
      apiFetch<Envelope<{ authorize_url: string }>>("/api/integrations/slack/oauth/start", {
        method: "POST",
        body: { redirect_uri: redirectUri },
      }),
  });
}

export function useSlackOauthCallback() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { code: string; state: string; redirect_uri: string }) =>
      apiFetch<
        Envelope<{
          connection: IntegrationConnection;
          connected_account?: string;
          provider_key: string;
        }>
      >("/api/integrations/slack/oauth/callback", {
        method: "POST",
        body,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["integrations"] });
      queryClient.invalidateQueries({ queryKey: ["mcp"] });
    },
  });
}

export function useNotionOauthStart() {
  return useMutation({
    mutationFn: (redirectUri: string) =>
      apiFetch<Envelope<{ authorize_url: string }>>("/api/integrations/notion/oauth/start", {
        method: "POST",
        body: { redirect_uri: redirectUri },
      }),
  });
}

export function useNotionOauthCallback() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { code: string; state: string; redirect_uri: string }) =>
      apiFetch<
        Envelope<{
          connection: IntegrationConnection;
          connected_account?: string;
          provider_key: string;
        }>
      >("/api/integrations/notion/oauth/callback", {
        method: "POST",
        body,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["integrations"] });
      queryClient.invalidateQueries({ queryKey: ["mcp"] });
    },
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

export function useCreditPacks() {
  const key = useWorkspaceKey("billing");
  return useQuery({
    queryKey: [...key, "credit-packs"],
    queryFn: () => apiFetch<Envelope<CreditPack[]>>("/api/billing/credit-packs"),
  });
}

/** Plan purchase — either activates directly or returns a PayMe checkout URL. */
export function usePlanCheckout() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { plan_key: string; billing_cycle?: string; return_path?: string }) =>
      apiFetch<Envelope<CheckoutResult>>("/api/billing/checkout", { method: "POST", body }),
    onSuccess: (result) => {
      if (result.data.sale_url) {
        window.location.href = result.data.sale_url;
      } else {
        queryClient.invalidateQueries({ queryKey: ["billing"] });
      }
    },
  });
}

/** AI credit pack purchase — same activation-or-redirect contract. */
export function useCreditsCheckout() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { pack_key: string; return_path?: string }) =>
      apiFetch<Envelope<CheckoutResult>>("/api/billing/credits/checkout", {
        method: "POST",
        body,
      }),
    onSuccess: (result) => {
      if (result.data.sale_url) {
        window.location.href = result.data.sale_url;
      } else {
        queryClient.invalidateQueries({ queryKey: ["billing"] });
      }
    },
  });
}

export function useUpdateAutoRecharge() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { enabled?: boolean; pack_key?: string; threshold?: number }) =>
      apiFetch<{ data: unknown }>("/api/billing/auto-recharge", { method: "POST", body }),
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

export function useCreateWorkspace() {
  return useMutation({
    mutationFn: (body: { name: string }) =>
      apiFetch<Envelope<Workspace>>("/api/workspaces", {
        method: "POST",
        body,
        skipWorkspace: true,
      }),
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

export function useUploadWorkspaceLogo() {
  const queryClient = useQueryClient();
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useMutation({
    mutationFn: (file: File) => {
      if (!workspaceId) {
        return Promise.reject(new Error("No workspace selected"));
      }
      const formData = new FormData();
      formData.append("file", file);
      return apiUpload<Envelope<Workspace>>(`/api/workspaces/${workspaceId}/logo`, formData);
    },
    onSuccess: (res) => {
      queryClient.setQueryData(["workspace", workspaceId], res);
      queryClient.invalidateQueries({ queryKey: ["workspace"] });
    },
  });
}

/* ---------- Onboarding (persisted in workspace.settings.onboarding) ---------- */

export function useOnboardingSettings(): {
  onboarding: OnboardingSettings;
  loaded: boolean;
} {
  const { data, isSuccess } = useWorkspace();
  const onboarding = ((data?.data.settings as Record<string, unknown> | null)?.onboarding ??
    {}) as OnboardingSettings;
  return { onboarding, loaded: isSuccess };
}

export function useUpdateOnboarding() {
  const queryClient = useQueryClient();
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useMutation({
    mutationFn: async (patch: Partial<OnboardingSettings>) => {
      // Read the latest settings so the merge never drops other keys.
      const current = await apiFetch<Envelope<Workspace>>(`/api/workspaces/${workspaceId}`);
      const settings = (current.data.settings ?? {}) as Record<string, unknown>;
      const onboarding = (settings.onboarding ?? {}) as OnboardingSettings;
      return apiFetch<Envelope<Workspace>>(`/api/workspaces/${workspaceId}`, {
        method: "PATCH",
        body: { settings: { ...settings, onboarding: { ...onboarding, ...patch } } },
      });
    },
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

/* ---------- Agent direct chat (floating dock) ---------- */

export function useAgentChats() {
  const key = useWorkspaceKey("agent-chats");
  return useQuery({
    queryKey: key,
    queryFn: () => apiFetch<Envelope<AgentChatSummary[]>>("/api/agent-chats"),
  });
}

export function useAgentChatMessages(agentId: string | null, conversationId?: string | null) {
  const key = useWorkspaceKey("agent-chat");
  return useQuery({
    queryKey: [...key, agentId, conversationId ?? null],
    enabled: agentId != null,
    queryFn: () => {
      const qs = conversationId ? `?conversation_id=${conversationId}` : "";
      return apiFetch<Envelope<AgentChatMessage[]>>(`/api/agents/${agentId}/chat${qs}`);
    },
  });
}

export function useSendAgentChatMessage(agentId: string) {
  const queryClient = useQueryClient();
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useMutation({
    mutationFn: (input: string | { body: string; drive_item_ids?: string[] }) => {
      const payload = typeof input === "string" ? { body: input } : input;
      return apiFetch<Envelope<AgentChatMessage>>(`/api/agents/${agentId}/chat`, {
        method: "POST",
        body: payload,
      });
    },
    onSuccess: (result) => {
      const msg = result.data;
      const append = (prev: Envelope<AgentChatMessage[]> | undefined) => {
        if (!prev) return prev;
        if (prev.data.some((m) => m.id === msg.id)) return prev;
        return { ...prev, data: [...prev.data, msg] };
      };

      queryClient.setQueriesData<Envelope<AgentChatMessage[]>>(
        { queryKey: ["agent-chat", workspaceId, agentId] },
        append,
      );
      queryClient.invalidateQueries({ queryKey: ["agent-chats"] });
    },
  });
}

export function useMarkAgentChatRead() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (agentId: string) =>
      apiFetch<{ data: { ok: boolean } }>(`/api/agents/${agentId}/chat/read`, { method: "POST" }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["agent-chats"] }),
  });
}

export function useAgentConversations(agentId: string | null) {
  const key = useWorkspaceKey("agent-conversations");
  return useQuery({
    queryKey: [...key, agentId],
    enabled: agentId != null,
    queryFn: () =>
      apiFetch<Envelope<AgentChatConversation[]>>(`/api/agents/${agentId}/conversations`),
  });
}

export function useNewConversation(agentId: string) {
  const queryClient = useQueryClient();
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useMutation({
    mutationFn: () =>
      apiFetch<Envelope<AgentChatConversation>>(
        `/api/agents/${agentId}/conversations/new`,
        { method: "POST" },
      ),
    onSuccess: (result) => {
      queryClient.invalidateQueries({ queryKey: ["agent-conversations"] });
      queryClient.invalidateQueries({ queryKey: ["agent-chats"] });
      queryClient.setQueryData<Envelope<AgentChatMessage[]>>(
        ["agent-chat", workspaceId, agentId, result.data.id],
        { data: [] },
      );
    },
  });
}
