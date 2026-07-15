import { useEffect } from "react";
import type { QueryClient } from "@tanstack/react-query";
import { useQueryClient } from "@tanstack/react-query";
import type { Agent, AgentChatMessage, AgentChatSummary, BillingOverview, Envelope } from "@/api/types";
import { useAuthStore } from "@/stores/auth-store";
import { toast } from "@/stores/toast-store";
import { useUiStore } from "@/stores/ui-store";
import { useChatStore } from "@/stores/chat-store";
import { useMissionPlanStore, type MissionPlanStep } from "@/stores/mission-plan-store";
import { useTaskTypingStore } from "@/stores/task-typing-store";
import { playSound } from "@/lib/sounds";
import { useReviewQueueStore } from "@/stores/review-queue-store";
import { joinChannel, onSocketOpen } from "./phoenix-client";

type EventPayload = Record<string, unknown>;

/** Suppress duplicate approval toasts for the same request (double broadcast / retries). */
const recentApprovalToasts = new Map<string, number>();
const APPROVAL_TOAST_TTL_MS = 30_000;

function shouldToastApproval(approvalRequestId: string | undefined): boolean {
  if (!approvalRequestId) return true;
  const now = Date.now();
  for (const [id, at] of recentApprovalToasts) {
    if (now - at > APPROVAL_TOAST_TTL_MS) recentApprovalToasts.delete(id);
  }
  if (recentApprovalToasts.has(approvalRequestId)) return false;
  recentApprovalToasts.set(approvalRequestId, now);
  return true;
}

/** Inserts a chat message into the cached thread + summary — no refetch. */
function insertChatMessage(
  queryClient: QueryClient,
  workspaceId: string,
  agentId: string,
  message: AgentChatMessage,
): void {
  let inserted = false;

  queryClient.setQueriesData<Envelope<AgentChatMessage[]>>(
    { queryKey: ["agent-chat", workspaceId, agentId] },
    (prev) => {
      if (!prev) return prev;
      if (prev.data.some((m) => m.id === message.id)) {
        inserted = true;
        return prev;
      }
      inserted = true;
      return { ...prev, data: [...prev.data, message] };
    },
  );

  if (!inserted) {
    queryClient.invalidateQueries({ queryKey: ["agent-chat", workspaceId, agentId] });
  }

  // Optimistic unread badge: bump instantly for agent replies when the
  // dock window isn't open — don't wait for the agent-chats refetch.
  const chatOpen = useChatStore.getState().openChatIds.includes(agentId);
  if (message.author_kind === "agent" && !chatOpen) {
    bumpUnreadCount(queryClient, workspaceId, agentId);
  }

  queryClient.invalidateQueries({ queryKey: ["agent-chats"] });
}

/** Instant unread badge on the floating dock without waiting for refetch. */
function bumpUnreadCount(
  queryClient: QueryClient,
  workspaceId: string,
  agentId: string,
): void {
  queryClient.setQueriesData<Envelope<AgentChatSummary[]>>(
    { queryKey: ["agent-chats", workspaceId] },
    (prev) => {
      if (!prev?.data) return prev;
      const exists = prev.data.some((s) => s.agent_id === agentId);
      if (!exists) return prev;
      return {
        ...prev,
        data: prev.data.map((s) =>
          s.agent_id === agentId ? { ...s, unread_count: (s.unread_count || 0) + 1 } : s,
        ),
      };
    },
  );
}

/** Patches the live AI-credit balance in the billing overview cache. */
function patchCreditsBalance(
  queryClient: QueryClient,
  workspaceId: string,
  payload: EventPayload,
): void {
  const spendable = typeof payload.spendable === "number" ? payload.spendable : undefined;
  const balance = typeof payload.balance === "number" ? payload.balance : undefined;
  const includedRemaining =
    typeof payload.included_remaining === "number" ? payload.included_remaining : undefined;
  if (spendable === undefined) return;

  queryClient.setQueryData<Envelope<BillingOverview>>(
    ["billing", workspaceId, "overview"],
    (prev) => {
      if (!prev?.data.credits) return prev;
    return {
      ...prev,
      data: {
          ...prev.data,
          credits: {
            ...prev.data.credits,
            spendable,
            balance: balance ?? prev.data.credits.balance,
            included_remaining: includedRemaining ?? prev.data.credits.included_remaining,
          },
        },
      };
    },
  );
}

/** Applies status broadcasts immediately while the background refetch verifies them. */
function patchAgentStatus(
  queryClient: QueryClient,
  workspaceId: string,
  payload: EventPayload,
): void {
  const agentId = str(payload, "agent_id");
  const status = str(payload, "status");
  if (!agentId || !status) return;

  const patch = (agent: Agent): Agent =>
    agent.id === agentId
      ? {
          ...agent,
          status: status as Agent["status"],
          presence_status:
            (str(payload, "presence_status") as Agent["presence_status"] | undefined) ??
            agent.presence_status,
          current_task_id:
            payload.current_task_id === null
              ? null
              : (str(payload, "current_task_id") ?? agent.current_task_id),
          office_activity:
            payload.office_activity === null
              ? null
              : (str(payload, "office_activity") ?? agent.office_activity),
          office_poi_id:
            payload.office_poi_id === null
              ? null
              : (str(payload, "office_poi_id") ?? agent.office_poi_id),
          office_slot_id:
            payload.office_slot_id === null
              ? null
              : (str(payload, "office_slot_id") ?? agent.office_slot_id),
          office_activity_phase:
            payload.office_activity_phase === null
              ? null
              : (str(payload, "office_activity_phase") ?? agent.office_activity_phase),
        }
      : agent;

  queryClient.setQueriesData<{ data: Agent[] | Agent }>(
    { queryKey: ["agents", workspaceId] },
    (previous) => {
      if (!previous) return previous;
      return {
        ...previous,
        data: Array.isArray(previous.data) ? previous.data.map(patch) : patch(previous.data),
      };
    },
  );
}

function patchOfficeActivity(
  queryClient: QueryClient,
  workspaceId: string,
  payload: EventPayload,
): void {
  const agentId = str(payload, "agent_id");
  if (!agentId) return;

  const patch = (agent: Agent): Agent =>
    agent.id === agentId
      ? {
          ...agent,
          office_activity:
            payload.office_activity === null
              ? null
              : (str(payload, "office_activity") ?? agent.office_activity),
          office_poi_id:
            payload.office_poi_id === null
              ? null
              : (str(payload, "office_poi_id") ?? agent.office_poi_id),
          office_slot_id:
            payload.office_slot_id === null
              ? null
              : (str(payload, "office_slot_id") ?? agent.office_slot_id),
          office_activity_phase:
            payload.office_activity_phase === null
              ? null
              : (str(payload, "office_activity_phase") ?? agent.office_activity_phase),
          office_activity_ends_at:
            payload.office_activity_ends_at === null
              ? null
              : (str(payload, "office_activity_ends_at") ?? agent.office_activity_ends_at),
        }
      : agent;

  queryClient.setQueriesData<{ data: Agent[] | Agent }>(
    { queryKey: ["agents", workspaceId] },
    (previous) => {
      if (!previous) return previous;
      return {
        ...previous,
        data: Array.isArray(previous.data) ? previous.data.map(patch) : patch(previous.data),
      };
    },
  );
}

function str(payload: EventPayload, key: string): string | undefined {
  const value = payload[key];
  return typeof value === "string" && value !== "" ? value : undefined;
}

/**
 * Realtime toasts for the task lifecycle. Backend broadcasts include the task
 * title only on the events worth surfacing, so payloads stay small elsewhere.
 */
function maybeToast(event: string, payload: EventPayload): void {
  const title = str(payload, "title");
  const taskId = str(payload, "task_id");

  switch (event) {
    case "task.created": {
      if (!title) return;
      const agentName = str(payload, "assigned_agent_name");
      playSound("task-start");
      toast({
        tone: "info",
        title: "Task created",
        description: agentName ? `"${title}" assigned to ${agentName}` : `"${title}"`,
        taskId,
      });
      return;
    }
    case "task.run_started": {
      if (!title) return;
      const agentName = str(payload, "agent_name") ?? "An agent";
      playSound("task-start");
      toast({
        tone: "working",
        title: `${agentName} is working on it`,
        description: `“${title}”`,
        taskId,
      });
      return;
    }
    case "task.progress_changed": {
      // Only terminal run states carry a title (see Mokaid.AI callbacks).
      if (!title) return;
      const status = str(payload, "status");
      if (status === "completed") {
        if (taskId) useUiStore.getState().flashTask(taskId);
        const agentName = str(payload, "agent_name") ?? "Your agent";
        playSound("task-done");
        if (taskId) {
          useReviewQueueStore.getState().enqueue(
            {
              taskId,
              kind: "in_review",
              title,
              agentName: str(payload, "agent_name"),
            },
            { open: true },
          );
        }
        toast({
          tone: "success",
          title: `${agentName} finished`,
          description: `"${title}": review the output and approve or request changes.`,
          taskId,
          duration: 10000,
        });
      } else if (status === "failed") {
        if (taskId) useUiStore.getState().flashTask(taskId);
        playSound("task-failed");
        toast({
          tone: "error",
          title: "Task failed",
          description: `"${title}": open the task to see what went wrong.`,
          taskId,
          duration: 8000,
        });
      }
      return;
    }
    case "task.approval_required": {
      playSound("attention");
      const approvalRequestId = str(payload, "approval_request_id");
      if (taskId) {
        useReviewQueueStore.getState().enqueue(
          {
            taskId,
            kind: "tool_approval",
            title: title ?? "Task",
            approvalRequestId,
            agentName: str(payload, "agent_name"),
          },
          { open: true },
        );
      }
      if (shouldToastApproval(approvalRequestId)) {
        toast({
          tone: "warning",
          title: "Approval needed",
          description: title
            ? `"${title}": the agent is waiting for your go-ahead.`
            : "An agent is waiting for your go-ahead.",
          taskId,
          duration: 12000,
        });
      }
      return;
    }
    case "task.completed": {
      if (!title) return;
      playSound("task-done");
      toast({ tone: "success", title: "Task completed", description: `“${title}”`, taskId });
      return;
    }
    case "notification.created": {
      const notifTitle = str(payload, "title") ?? "New notification";
      const kind = str(payload, "kind");
      // Skip kinds already toasted via task lifecycle to avoid doubles.
      if (
        kind === "ai_run_completed" ||
        kind === "ai_run_failed" ||
        kind === "approval_requested"
      ) {
        return;
      }
      playSound("attention");
      toast({
        tone: "info",
        title: notifTitle,
        description: kind ? kind.replace(/_/g, " ") : undefined,
        duration: 6000,
      });
      return;
    }
    case "agent.level_up": {
      const agentName = str(payload, "agent_name") ?? "Your agent";
      const level = typeof payload.level === "number" ? payload.level : undefined;
      playSound("task-done");
      toast({
        tone: "success",
        title: `${agentName} leveled up!`,
        description: level ? `Now level ${level} — its expertise keeps growing.` : undefined,
        duration: 6000,
      });
      return;
    }
    default:
  }
}

/**
 * Joins the workspace channel, invalidates the relevant queries when compact
 * realtime events arrive, and surfaces lifecycle toasts.
 */
export function useWorkspaceChannel(): void {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const token = useAuthStore((s) => s.token);
  const userId = useAuthStore((s) => s.user?.id ?? null);
  const queryClient = useQueryClient();

  useEffect(() => {
    if (!workspaceId || !token) return;

    const topic = `workspace:${workspaceId}`;
    const channel = joinChannel(topic);
    if (!channel) return;

    // Personal notifications topic — badge on the topbar bell + toast.
    // Backend broadcasts notification.created here, NOT on workspace:*.
    const notifChannel = userId ? joinChannel(`notifications:${userId}`) : null;

    const invalidate = (keys: string[][]) => {
      keys.forEach((key) => queryClient.invalidateQueries({ queryKey: key }));
    };

    const bindings: Array<[string, string[][]]> = [
      ["agent.created", [["agents"]]],
      ["agent.updated", [["agents"]]],
      ["agent.status_changed", [["agents"], ["dashboard"]]],
      ["agent.linked_user_changed", [["agents"], ["members"]]],
      ["agent.level_up", [["agents"]]],
      ["task.created", [["tasks"], ["dashboard"]]],
      ["task.updated", [["tasks"]]],
      ["task.status_changed", [["tasks"], ["dashboard"], ["analytics"]]],
      ["task.assigned", [["tasks"], ["agents"]]],
      ["task.run_started", [["tasks"], ["agents"]]],
      ["task.progress_changed", [["tasks"]]],
      ["task.completed", [["tasks"], ["dashboard"], ["analytics"]]],
      ["task.approval_required", [["tasks"], ["approvals"]]],
      ["task.comment_added", [["tasks"]]],
      ["project.created", [["projects"]]],
      ["project.updated", [["projects"]]],
      ["project.deleted", [["projects"], ["tasks"], ["dashboard"]]],
      ["knowledge.uploaded", [["knowledge"]]],
      ["knowledge.indexed", [["knowledge"]]],
      ["calendar.event_created", [["calendar"]]],
      ["leave_request.created", [["leave-requests"]]],
      ["leave_request.approved", [["leave-requests"], ["calendar"]]],
      ["leave_request.rejected", [["leave-requests"]]],
      ["notification.created", [["notifications"]]],
      ["billing.updated", [["billing"]]],
    ];

    const refs = bindings.map(([event, keys]) =>
      channel.on(event, (payload: EventPayload) => {
        invalidate(keys);
        maybeToast(event, payload ?? {});
      }),
    );

    // Agent chat: insert the message straight into the cache so it appears
    // instantly (no refetch round-trip). The broadcast carries the full
    // serialized message.
    const chatMsgRef = channel.on("agent_chat.message", (payload: EventPayload) => {
      const agentId = str(payload ?? {}, "agent_id");
      const message = (payload as { message?: AgentChatMessage }).message;
      if (!agentId || !message) return;

      insertChatMessage(queryClient, workspaceId, agentId, message);

      if (message.author_kind === "agent") {
        useChatStore.getState().clearAgentTyping(agentId);
        // Clear the matching typewriter draft (or any draft if no stream_id).
        useChatStore.getState().finalizeStream(agentId, str(payload ?? {}, "stream_id"));
        playSound("message");
      }
    });

    // Token-by-token reply stream: grow the agent's draft bubble live. The
    // final `agent_chat.message` broadcast swaps the draft for the real thing.
    // `done: true` also clears the draft so late empty/partial packets don't linger.
    const chatChunkRef = channel.on("agent_chat.chunk", (payload: EventPayload) => {
      const agentId = str(payload ?? {}, "agent_id");
      const streamId = str(payload ?? {}, "stream_id");
      if (!agentId || !streamId) return;
      const done = payload.done === true;
      const chunk = typeof payload.chunk === "string" ? payload.chunk : "";
      if (done) {
        useChatStore.getState().clearAgentTyping(agentId);
        useChatStore.getState().markStreamDone(agentId, streamId);
        void queryClient
          .invalidateQueries({ queryKey: ["agent-chat", workspaceId, agentId] })
          .then(() => {
            const draft = useChatStore.getState().streamingDrafts[agentId];
            if (!draft || draft.streamId !== streamId) return;
            const allCached = queryClient.getQueriesData<Envelope<AgentChatMessage[]>>({
              queryKey: ["agent-chat", workspaceId, agentId],
            });
            const persisted = allCached.some(([, data]) =>
              data?.data.some((m) => m.author_kind === "agent" && m.body === draft.text),
            );
            if (persisted) {
              useChatStore.getState().finalizeStream(agentId, streamId);
            }
          });
        return;
      }
      if (chunk) {
        useChatStore.getState().clearAgentTyping(agentId);
        useChatStore.getState().appendStreamChunk(agentId, streamId, chunk);
      }
    });

    // Live AI-credit balance: patch the billing overview cache in place so the
    // consumption meter ticks down without a refetch.
    const creditsRef = channel.on("credits.updated", (payload: EventPayload) => {
      patchCreditsBalance(queryClient, workspaceId, payload);
    });

    const agentStatusRef = channel.on("agent.status_changed", (payload: EventPayload) => {
      patchAgentStatus(queryClient, workspaceId, payload);
    });

    const officeActivityRef = channel.on("agent.office_activity", (payload: EventPayload) => {
      patchOfficeActivity(queryClient, workspaceId, payload);
    });

    // Typing indicator on: broadcast when a member message is queued for an
    // AI reply (kept out of `bindings` — no queries to invalidate).
    const typingRef = channel.on("agent_chat.typing", (payload: EventPayload) => {
      const agentId = str(payload ?? {}, "agent_id");
      if (agentId) useChatStore.getState().setAgentTyping(agentId);
    });

    // Task-thread typing: the agent starts "typing" the moment the reply job
    // is queued; its comment landing (task.comment_added) clears it.
    const taskTypingRef = channel.on("task.agent_typing", (payload: EventPayload) => {
      const taskId = str(payload ?? {}, "task_id");
      if (taskId) useTaskTypingStore.getState().setTyping(taskId);
    });

    const commentRef = channel.on("task.comment_added", (payload: EventPayload) => {
      const taskId = str(payload ?? {}, "task_id");
      if (taskId) useTaskTypingStore.getState().clearTyping(taskId);
    });

    // Deep-agent live plan: patch the mission checklist store directly so the
    // task panel ticks todos in real time without a refetch.
    const planRef = channel.on("task.plan_updated", (payload: EventPayload) => {
      const taskId = str(payload ?? {}, "task_id");
      const steps = (payload as { steps?: MissionPlanStep[] }).steps;
      if (taskId && Array.isArray(steps)) {
        useMissionPlanStore.getState().setPlan(taskId, steps);
      }
    });

    // Personal notifications: badge + toast. Must live on notifications:{userId}
    // — never arrives on the workspace channel.
    const notifRef = notifChannel?.on("notification.created", (payload: EventPayload) => {
      queryClient.invalidateQueries({ queryKey: ["notifications"] });
      maybeToast("notification.created", payload ?? {});
    });

    // Catch-up on reconnect: any event broadcast while the socket was down
    // (server restart, laptop sleep, network blip) was lost — refetch the
    // realtime-backed data so the UI never sits on a stale pipeline.
    let firstOpen = true;
    const offOpen = onSocketOpen(() => {
      if (!firstOpen) {
        invalidate([
          ["tasks"],
          ["agents"],
          ["dashboard"],
          ["notifications"],
          ["analytics"],
          ["agent-chat"],
          ["agent-chats"],
        ]);
      }
      firstOpen = false;
    });

    return () => {
      offOpen?.();
      // Unbind only our handlers. Do NOT leave the channel: it's a
      // session-long shared subscription (one per workspace). Leaving it on
      // every effect cleanup — which React StrictMode triggers on mount in
      // dev, and any dependency change triggers in prod — tears down the
      // socket subscription and races a rejoin, during which broadcast events
      // (chat replies, credit updates) are silently dropped. The channel is
      // closed for real at logout via phoenix-client `disconnect()`.
      bindings.forEach(([event], index) => channel.off(event, refs[index]));
      channel.off("agent_chat.message", chatMsgRef);
      channel.off("agent_chat.chunk", chatChunkRef);
      channel.off("credits.updated", creditsRef);
      channel.off("agent.status_changed", agentStatusRef);
      channel.off("agent.office_activity", officeActivityRef);
      channel.off("agent_chat.typing", typingRef);
      channel.off("task.agent_typing", taskTypingRef);
      channel.off("task.comment_added", commentRef);
      channel.off("task.plan_updated", planRef);
      if (notifChannel && notifRef != null) {
        notifChannel.off("notification.created", notifRef);
      }
    };
  }, [workspaceId, token, userId, queryClient]);
}
