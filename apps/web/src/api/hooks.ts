import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiFetch, apiUpload } from "./client";
import type {
  Agent,
  AgentCatalog,
  AgentChatConversation,
  AgentChatMessage,
  AgentChatSummary,
  AgentPermissionRule,
  AgentProgression,
  AgentSchedule,
  AgentTrainingSnapshot,
  ScheduleDraft,
  AgentCounts,
  AnalyticsOverview,
  CreateAgentPayload,
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
  MailAccount,
  MailMessage,
  MailRule,
  McpGrant,
  McpInstallation,
  McpServer,
  Member,
  OnboardingSettings,
  Project,
  ProjectActivity,
  Task,
  TaskComment,
  TaskRun,
  Workspace,
} from "./types";
import { useAuthStore, type WorkspaceSummary } from "@/stores/auth-store";

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

function useWorkspaceKey(base: string): {
  key: (string | null)[];
  workspaceId: string | null;
  enabled: boolean;
} {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return {
    key: [base, workspaceId],
    workspaceId,
    enabled: workspaceId != null,
  };
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("agents");
  return useQuery({
    queryKey: [...key, filters],
    enabled: workspaceReady,
    queryFn: () =>
      apiFetch<{ data: Agent[]; meta: { counts: AgentCounts } }>("/api/agents", {
        params: filters,
      }),
  });
}

export function useAgent(id: string | null) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("agents");
  return useQuery({
    queryKey: [...key, "detail", id],
    enabled: workspaceReady && id != null,
    queryFn: () => apiFetch<Envelope<Agent>>(`/api/agents/${id}`),
  });
}

export function useAgentProgression(id: string | null) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("agents");
  return useQuery({
    queryKey: [...key, "progression", id],
    enabled: workspaceReady && id != null,
    queryFn: () => apiFetch<Envelope<AgentProgression>>(`/api/agents/${id}/progression`),
  });
}

export function useAgentTraining(id: string | null) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("agents");
  return useQuery({
    queryKey: [...key, "training", id],
    enabled: workspaceReady && id != null,
    queryFn: () => apiFetch<Envelope<AgentTrainingSnapshot>>(`/api/agents/${id}/training`),
    refetchInterval: (query) => (query.state.data?.data.complete ? false : 1_200),
  });
}

export function useAgentCatalog() {
  return useQuery({
    queryKey: ["agents", "catalog"],
    queryFn: () => apiFetch<Envelope<AgentCatalog>>("/api/agents/catalog"),
    staleTime: 60_000,
  });
}

export function useCreateAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: CreateAgentPayload) =>
      apiFetch<Envelope<Agent>>("/api/agents", { method: "POST", body }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["agents"] });
      queryClient.invalidateQueries({ queryKey: ["billing"] });
    },
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

/* Persisted allow/deny tool rules (agent autonomy). */

export function useAgentPermissionRules(agentId: string | null) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("agents");
  return useQuery({
    queryKey: [...key, "permission-rules", agentId],
    enabled: workspaceReady && agentId != null,
    queryFn: () =>
      apiFetch<Envelope<AgentPermissionRule[]>>(
        `/api/agents/${agentId}/permission-rules`,
      ),
  });
}

export function useCreateAgentPermissionRule() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      agentId,
      toolPattern,
      behavior,
    }: {
      agentId: string;
      toolPattern: string;
      behavior: "allow" | "deny";
    }) =>
      apiFetch<Envelope<AgentPermissionRule>>(
        `/api/agents/${agentId}/permission-rules`,
        { method: "POST", body: { tool_pattern: toolPattern, behavior } },
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["agents"] }),
  });
}

export function useDeleteAgentPermissionRule() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ agentId, ruleId }: { agentId: string; ruleId: string }) =>
      apiFetch<{ ok: boolean }>(
        `/api/agents/${agentId}/permission-rules/${ruleId}`,
        { method: "DELETE" },
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["agents"] }),
  });
}

/* Agent automations (cron schedules). */

export function useAgentSchedules(agentId: string | null) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("agents");
  return useQuery({
    queryKey: [...key, "schedules", agentId],
    enabled: workspaceReady && agentId != null,
    queryFn: () =>
      apiFetch<Envelope<AgentSchedule[]>>(`/api/agents/${agentId}/schedules`),
  });
}

export function useCreateAgentSchedule() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      agentId,
      ...body
    }: {
      agentId: string;
      name: string;
      cron_expression: string;
      timezone?: string;
      prompt: string;
      enabled?: boolean;
      max_runs?: number | null;
      expires_at?: string | null;
    }) =>
      apiFetch<Envelope<AgentSchedule>>(`/api/agents/${agentId}/schedules`, {
        method: "POST",
        body,
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["agents"] }),
  });
}

export function useUpdateAgentSchedule() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      agentId,
      scheduleId,
      ...body
    }: {
      agentId: string;
      scheduleId: string;
    } & Partial<
      Pick<AgentSchedule, "name" | "cron_expression" | "timezone" | "prompt" | "enabled">
    >) =>
      apiFetch<Envelope<AgentSchedule>>(
        `/api/agents/${agentId}/schedules/${scheduleId}`,
        { method: "PATCH", body },
      ),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["agents"] }),
  });
}

export function useDeleteAgentSchedule() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ agentId, scheduleId }: { agentId: string; scheduleId: string }) =>
      apiFetch<{ ok: boolean }>(`/api/agents/${agentId}/schedules/${scheduleId}`, {
        method: "DELETE",
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["agents"] }),
  });
}

/** Natural-language → cron draft ("every Monday 9am, prepare the report"). */
export function useParseAgentSchedule() {
  return useMutation({
    mutationFn: ({ agentId, text }: { agentId: string; text: string }) =>
      apiFetch<Envelope<ScheduleDraft>>(`/api/agents/${agentId}/schedules/parse`, {
        method: "POST",
        body: { text },
      }),
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

/**
 * Paid cross-workspace copy: clones the agent (and its knowledge, copied in
 * the background) into another workspace of the current user. The target
 * workspace is debited one agent's price in credits.
 */
export function useTransferAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      agentId,
      targetWorkspaceId,
    }: {
      agentId: string;
      targetWorkspaceId: string;
    }) =>
      apiFetch<{
        data: Agent;
        meta: { knowledge_copy: string; credits_charged: number };
      }>(`/api/agents/${agentId}/transfer`, {
        method: "POST",
        body: { target_workspace_id: targetWorkspaceId },
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["agents"] });
      queryClient.invalidateQueries({ queryKey: ["billing"] });
    },
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("tasks");
  return useQuery({
    queryKey: [...key, filters],
    enabled: workspaceReady,
    queryFn: () =>
      apiFetch<{
        data: Task[];
        meta: { counts: Record<string, number>; completed_today: number };
      }>("/api/tasks", { params: filters }),
  });
}

export function useTask(id: string | null) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("tasks");
  return useQuery({
    queryKey: [...key, "detail", id],
    enabled: workspaceReady && id != null,
    queryFn: () => apiFetch<Envelope<Task>>(`/api/tasks/${id}`),
  });
}

/** Full run history of a task (newest first) — powers the run timeline. */
export function useTaskRuns(id: string | null, opts?: { enabled?: boolean }) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("tasks");
  return useQuery({
    queryKey: [...key, "runs", id],
    enabled: workspaceReady && id != null && (opts?.enabled ?? true),
    queryFn: () => apiFetch<Envelope<TaskRun[]>>(`/api/tasks/${id}/runs`),
  });
}

export function useCreateTask() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: Partial<Task> & { title: string; metadata?: Record<string, unknown> }) =>
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

/** Human decision on an agent's pending approval request (approve / reject / edited). */
export function useApproveTaskAction() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      taskId,
      approvalRequestId,
      decision,
      payload,
      remember,
    }: {
      taskId: string;
      approvalRequestId: string;
      decision: "approved" | "rejected" | "edited";
      payload?: Record<string, unknown>;
      /** Persist an always-allow / always-deny rule for this agent+tool. */
      remember?: "allow" | "deny";
    }) =>
      apiFetch<Envelope<{ id: string; status: string }>>(`/api/tasks/${taskId}/approve-action`, {
        method: "POST",
        body: {
          approval_request_id: approvalRequestId,
          decision,
          ...(payload ? { payload } : {}),
          ...(remember ? { remember } : {}),
        },
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
      capability_match?: {
        mode: string;
        confidence: number;
        reason: string;
        warning_shown: boolean;
      };
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("projects");
  return useQuery({
    queryKey: [...key, filters],
    enabled: workspaceReady,
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

export function useAddProjectAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ projectId, agentId }: { projectId: string; agentId: string }) =>
      apiFetch<Envelope<Project>>(`/api/projects/${projectId}/agents`, {
        method: "POST",
        body: { agent_id: agentId },
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["projects"] }),
  });
}

export function useRemoveProjectAgent() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ projectId, agentId }: { projectId: string; agentId: string }) =>
      apiFetch<Envelope<Project>>(`/api/projects/${projectId}/agents/${agentId}`, {
        method: "DELETE",
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["projects"] }),
  });
}

export function useDeleteProject() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<{ ok: boolean }>(`/api/projects/${id}`, { method: "DELETE" }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["projects"] });
      queryClient.invalidateQueries({ queryKey: ["tasks"] });
      queryClient.invalidateQueries({ queryKey: ["dashboard"] });
    },
  });
}

/* ---------- Knowledge ---------- */

export function useKnowledgeItems(filters: Record<string, string | undefined> = {}) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("knowledge");
  return useQuery({
    queryKey: [...key, filters],
    enabled: workspaceReady,
    queryFn: () =>
      apiFetch<{ data: KnowledgeItem[]; meta: { counts: Record<string, number> } }>(
        "/api/knowledge",
        { params: filters },
      ),
  });
}

/** Item detail — the only endpoint that ships the full body. */
export function useKnowledgeItem(id: string | null) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("knowledge");
  return useQuery({
    queryKey: [...key, "detail", id],
    enabled: workspaceReady && id != null,
    queryFn: () => apiFetch<Envelope<KnowledgeItem>>(`/api/knowledge/${id}`),
  });
}

export function useDeleteKnowledgeItem() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<{ ok: boolean }>(`/api/knowledge/${id}`, { method: "DELETE" }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["knowledge"] }),
  });
}

export function useKnowledgeCategories() {
  const { key, enabled: workspaceReady } = useWorkspaceKey("knowledge");
  return useQuery({
    queryKey: [...key, "categories"],
    enabled: workspaceReady,
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

export function useUploadKnowledgeFiles() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ files, categoryId }: { files: File[]; categoryId?: string }) => {
      const formData = new FormData();
      for (const file of files) formData.append("files[]", file);
      if (categoryId) formData.append("category_id", categoryId);
      return apiUpload<Envelope<KnowledgeItem[]>>("/api/knowledge/upload", formData);
    },
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["knowledge"] }),
  });
}

export function useKnowledgeGraph(filters: Record<string, string | undefined> = {}) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("knowledge-graph");
  return useQuery({
    queryKey: [...key, filters],
    enabled: workspaceReady,
    queryFn: () =>
      apiFetch<Envelope<import("@/three/knowledge-zones").KnowledgeGraphSnapshot>>(
        "/api/knowledge-graph",
        { params: filters },
      ).then((r) => r.data),
  });
}

export function useKnowledgeOfficeZones() {
  const { key, enabled: workspaceReady } = useWorkspaceKey("knowledge-graph-zones");
  return useQuery({
    queryKey: key,
    enabled: workspaceReady,
    queryFn: () =>
      apiFetch<Envelope<import("@/three/knowledge-zones").KnowledgeCommunity[]>>(
        "/api/knowledge-graph/office-zones",
      ).then((r) => r.data),
  });
}

export function useRebuildKnowledgeGraph() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: Record<string, string | undefined> = {}) =>
      apiFetch<Envelope<{ communities: number }>>("/api/knowledge-graph/rebuild", {
        method: "POST",
        body,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["knowledge-graph"] });
      queryClient.invalidateQueries({ queryKey: ["knowledge-graph-zones"] });
    },
  });
}

export function useReindexKnowledgeGraph() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: Record<string, string | undefined> = {}) =>
      apiFetch<Envelope<{ requeued: number; credits_charged: number }>>(
        "/api/knowledge-graph/reindex",
        { method: "POST", body },
      ),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["knowledge"] });
      queryClient.invalidateQueries({ queryKey: ["knowledge-graph"] });
      queryClient.invalidateQueries({ queryKey: ["billing"] });
    },
  });
}

export function useCompanyBrain() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      notes?: Array<{ title?: string; body?: string; content?: string }>;
    }) =>
      apiFetch<Envelope<import("@/three/knowledge-zones").CompanyBrainReport>>(
        "/api/knowledge-graph/company-brain",
        { method: "POST", body },
      ).then((r) => r.data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["knowledge"] });
      queryClient.invalidateQueries({ queryKey: ["knowledge-graph"] });
    },
  });
}

/* ---------- Drive ---------- */

export function useDriveItems(parentId: string | null) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("drive");
  return useQuery({
    queryKey: [...key, parentId],
    enabled: workspaceReady,
    queryFn: () =>
      apiFetch<Envelope<DriveItem[]>>("/api/drive", {
        params: { parent_id: parentId ?? undefined },
      }),
  });
}

export function useDriveTrash() {
  const { key, enabled: workspaceReady } = useWorkspaceKey("drive");
  return useQuery({
    queryKey: [...key, "trash"],
    enabled: workspaceReady,
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("calendar");
  return useQuery({
    queryKey: [...key, filters],
    enabled: workspaceReady,
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("members");
  return useQuery({
    queryKey: key,
    enabled: workspaceReady,
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

export function useRemoveMember() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<{ ok: boolean }>(`/api/members/${id}`, { method: "DELETE" }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["members"] });
      queryClient.invalidateQueries({ queryKey: ["agents"] });
    },
  });
}

export function useCancelInvite() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<{ ok: boolean }>(`/api/members/invites/${id}`, { method: "DELETE" }),
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("leave-requests");
  return useQuery({
    queryKey: key,
    enabled: workspaceReady,
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("integrations");
  return useQuery({
    queryKey: key,
    enabled: workspaceReady,
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("mcp");
  return useQuery({
    queryKey: key,
    enabled: workspaceReady,
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
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useQuery({
    queryKey: ["mcp-grants", workspaceId, agentId],
    enabled: workspaceId != null && agentId != null,
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

export function useMicrosoftOauthStart() {
  return useMutation({
    mutationFn: (redirectUri: string) =>
      apiFetch<Envelope<{ authorize_url: string }>>("/api/integrations/microsoft/oauth/start", {
        method: "POST",
        body: { redirect_uri: redirectUri },
      }),
  });
}

export function useMicrosoftOauthCallback() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { code: string; state: string; redirect_uri: string }) =>
      apiFetch<
        Envelope<{
          connection: IntegrationConnection;
          connected_account?: string;
          provider_key: string;
        }>
      >("/api/integrations/microsoft/oauth/callback", {
        method: "POST",
        body,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["integrations"] });
      queryClient.invalidateQueries({ queryKey: ["mcp"] });
      queryClient.invalidateQueries({ queryKey: ["mail"] });
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("billing");
  return useQuery({
    queryKey: [...key, "overview"],
    enabled: workspaceReady,
    queryFn: () => apiFetch<Envelope<BillingOverview>>("/api/billing/overview"),
  });
}

export function useInvoices() {
  const { key, enabled: workspaceReady } = useWorkspaceKey("billing");
  return useQuery({
    queryKey: [...key, "invoices"],
    enabled: workspaceReady,
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("billing");
  return useQuery({
    queryKey: [...key, "plans"],
    enabled: workspaceReady,
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("billing");
  return useQuery({
    queryKey: [...key, "credit-packs"],
    enabled: workspaceReady,
    queryFn: () => apiFetch<Envelope<CreditPack[]>>("/api/billing/credit-packs"),
  });
}

/**
 * Plan purchase — either activates directly (free plan / dev fallback) or
 * returns a Tranzila `sale_url` the caller embeds in the on-site checkout
 * modal (`TranzilaCheckoutDialog`). No external redirect.
 */
export function usePlanCheckout() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { plan_key: string; billing_cycle?: string }) =>
      apiFetch<Envelope<CheckoutResult>>("/api/billing/checkout", { method: "POST", body }),
    onSuccess: (result) => {
      if (!result.data.sale_url) {
        queryClient.invalidateQueries({ queryKey: ["billing"] });
      }
    },
  });
}

/** AI credit pack purchase — same activation-or-embedded-checkout contract. */
export function useCreditsCheckout() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { pack_key: string }) =>
      apiFetch<Envelope<CheckoutResult>>("/api/billing/credits/checkout", {
        method: "POST",
        body,
      }),
    onSuccess: (result) => {
      if (!result.data.sale_url) {
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("analytics");
  return useQuery({
    queryKey: [...key, "overview"],
    enabled: workspaceReady,
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

export type MeUser = {
  id: string;
  email: string;
  full_name: string;
  avatar_url: string | null;
  has_avatar?: boolean;
  has_password?: boolean;
  locale?: string;
  timezone?: string;
  mfa_enabled?: boolean;
  last_login_at?: string | null;
  auth_provider?: string;
};

export function useMe() {
  const token = useAuthStore((s) => s.token);
  return useQuery({
    queryKey: ["me"],
    enabled: Boolean(token),
    queryFn: () =>
      apiFetch<{
        user: MeUser;
        workspaces: WorkspaceSummary[];
      }>("/api/me", { skipWorkspace: true }),
  });
}

function syncAuthUser(user: MeUser) {
  const { token, patchUser, setSession } = useAuthStore.getState();
  if (!token) return;
  const next = {
    id: user.id,
    email: user.email,
    full_name: user.full_name,
    avatar_url: user.avatar_url,
    has_avatar: user.has_avatar,
    has_password: user.has_password,
    locale: user.locale,
    timezone: user.timezone,
    mfa_enabled: user.mfa_enabled,
    last_login_at: user.last_login_at,
    auth_provider: user.auth_provider,
  };
  if (useAuthStore.getState().user) {
    patchUser(next);
  } else {
    setSession(token, next);
  }
}

export function useUpdateMe() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: { full_name?: string; locale?: string; timezone?: string }) =>
      apiFetch<{ user: MeUser }>("/api/me", {
        method: "PATCH",
        body,
        skipWorkspace: true,
      }),
    onSuccess: (res) => {
      syncAuthUser(res.user);
      queryClient.setQueryData(["me"], (prev: { user: MeUser; workspaces: WorkspaceSummary[] } | undefined) =>
        prev ? { ...prev, user: res.user } : prev,
      );
      queryClient.invalidateQueries({ queryKey: ["me"] });
    },
  });
}

export function useUploadAvatar() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (file: File) => {
      const formData = new FormData();
      formData.append("file", file);
      return apiUpload<{ user: MeUser }>("/api/me/avatar", formData);
    },
    onSuccess: (res) => {
      syncAuthUser(res.user);
      queryClient.setQueryData(["me"], (prev: { user: MeUser; workspaces: WorkspaceSummary[] } | undefined) =>
        prev ? { ...prev, user: res.user } : prev,
      );
      queryClient.invalidateQueries({ queryKey: ["me"] });
    },
  });
}

export function useRemoveAvatar() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () =>
      apiFetch<{ user: MeUser }>("/api/me/avatar", {
        method: "DELETE",
        skipWorkspace: true,
      }),
    onSuccess: (res) => {
      syncAuthUser(res.user);
      queryClient.setQueryData(["me"], (prev: { user: MeUser; workspaces: WorkspaceSummary[] } | undefined) =>
        prev ? { ...prev, user: res.user } : prev,
      );
      queryClient.invalidateQueries({ queryKey: ["me"] });
    },
  });
}

export function useChangePassword() {
  return useMutation({
    mutationFn: (body: {
      current_password: string;
      password: string;
      password_confirmation: string;
    }) =>
      apiFetch<{ ok: boolean }>("/api/me/password", {
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("notifications");
  return useQuery({
    queryKey: key,
    enabled: workspaceReady,
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("agent-chats");
  return useQuery({
    queryKey: key,
    enabled: workspaceReady,
    queryFn: () => apiFetch<Envelope<AgentChatSummary[]>>("/api/agent-chats"),
  });
}

export function useAgentChatMessages(agentId: string | null, conversationId?: string | null) {
  const { key, enabled: workspaceReady } = useWorkspaceKey("agent-chat");
  return useQuery({
    queryKey: [...key, agentId, conversationId ?? null],
    enabled: workspaceReady && agentId != null,
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
  const { key, enabled: workspaceReady } = useWorkspaceKey("agent-conversations");
  return useQuery({
    queryKey: [...key, agentId],
    enabled: workspaceReady && agentId != null,
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

/* ─── Mail (connected mailboxes + AI rules) ─── */

export function useMailAccounts() {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useQuery({
    queryKey: ["mail", "accounts", workspaceId],
    queryFn: () => apiFetch<Envelope<MailAccount[]>>("/api/mail/accounts"),
    enabled: Boolean(workspaceId),
  });
}

export function useCreateImapAccount() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      email_address: string;
      password: string;
      imap_host: string;
      imap_port?: number;
      username?: string;
      smtp_host?: string;
      smtp_port?: number;
      display_name?: string;
    }) =>
      apiFetch<Envelope<MailAccount>>("/api/mail/accounts/imap", {
        method: "POST",
        body,
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mail"] }),
  });
}

export function useDeleteMailAccount() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<Envelope<{ deleted: boolean }>>(`/api/mail/accounts/${id}`, {
        method: "DELETE",
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mail"] }),
  });
}

export function useSyncMailAccount() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<Envelope<{ queued: boolean }>>(`/api/mail/accounts/${id}/sync`, {
        method: "POST",
      }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mail"] }),
  });
}

export function useMailMessages(filters?: {
  account_id?: string;
  q?: string;
  min_importance?: number;
  limit?: number;
}) {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const params = new URLSearchParams();
  if (filters?.account_id) params.set("account_id", filters.account_id);
  if (filters?.q) params.set("q", filters.q);
  if (filters?.min_importance != null) params.set("min_importance", String(filters.min_importance));
  if (filters?.limit != null) params.set("limit", String(filters.limit));
  const suffix = params.toString() ? `?${params.toString()}` : "";
  return useQuery({
    queryKey: ["mail", "messages", workspaceId, suffix],
    queryFn: () => apiFetch<Envelope<MailMessage[]>>(`/api/mail/messages${suffix}`),
    enabled: Boolean(workspaceId),
    refetchInterval: 60_000,
  });
}

export function useMailMessage(id: string | null) {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useQuery({
    queryKey: ["mail", "message", workspaceId, id],
    queryFn: () => apiFetch<Envelope<MailMessage>>(`/api/mail/messages/${id}`),
    enabled: Boolean(workspaceId && id),
  });
}

export function useMailRules() {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  return useQuery({
    queryKey: ["mail", "rules", workspaceId],
    queryFn: () => apiFetch<Envelope<MailRule[]>>("/api/mail/rules"),
    enabled: Boolean(workspaceId),
  });
}

export function useCreateMailRule() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      name: string;
      prompt: string;
      action?: string;
      mail_account_id?: string;
    }) =>
      apiFetch<Envelope<MailRule>>("/api/mail/rules", { method: "POST", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mail", "rules"] }),
  });
}

export function useUpdateMailRule() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: { id: string } & Partial<Pick<MailRule, "name" | "prompt" | "action" | "enabled">>) =>
      apiFetch<Envelope<MailRule>>(`/api/mail/rules/${id}`, { method: "PATCH", body }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mail", "rules"] }),
  });
}

export function useDeleteMailRule() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) =>
      apiFetch<Envelope<{ deleted: boolean }>>(`/api/mail/rules/${id}`, { method: "DELETE" }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["mail", "rules"] }),
  });
}
