import { useEffect } from "react";
import type { QueryClient } from "@tanstack/react-query";
import { useQueryClient } from "@tanstack/react-query";
import type { AgentChatMessage, BillingOverview, Envelope } from "@/api/types";
import { useAuthStore } from "@/stores/auth-store";
import { toast } from "@/stores/toast-store";
import { useUiStore } from "@/stores/ui-store";
import { useChatStore } from "@/stores/chat-store";
import { useMissionPlanStore, type MissionPlanStep } from "@/stores/mission-plan-store";
import { useTaskTypingStore } from "@/stores/task-typing-store";
import { playSound } from "@/lib/sounds";
import { joinChannel, onSocketOpen } from "./phoenix-client";

type EventPayload = Record<string, unknown>;

/** Inserts a chat message into the cached thread + summary — no refetch. */
function insertChatMessage(
  queryClient: QueryClient,
  workspaceId: string,
  agentId: string,
  message: AgentChatMessage,
): void {
  const key = ["agent-chat", workspaceId, agentId];
  const existing = queryClient.getQueryData<Envelope<AgentChatMessage[]>>(key);

  if (existing) {
    // Thread is loaded — append in place (dedupe on id) for instant render.
    if (!existing.data.some((m) => m.id === message.id)) {
      queryClient.setQueryData<Envelope<AgentChatMessage[]>>(key, {
        ...existing,
        data: [...existing.data, message],
      });
    }
  } else {
    // Thread not in cache yet (window just opened, or first message ever) —
    // invalidate so it refetches with the new message instead of missing it.
    queryClient.invalidateQueries({ queryKey: key });
  }

  // Summaries (last message + unread badge) always refresh.
  queryClient.invalidateQueries({ queryKey: ["agent-chats"] });
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
        playSound("task-done");
        toast({
          tone: "success",
          title: "Ready for review",
          description: `"${title}": the agent finished. Check the output.`,
          taskId,
          duration: 8000,
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
      toast({
        tone: "info",
        title: "Approval needed",
        description: title
          ? `"${title}": the agent is waiting for your go-ahead.`
          : "An agent is waiting for your go-ahead.",
        taskId,
        duration: 10000,
      });
      return;
    }
    case "task.completed": {
      if (!title) return;
      toast({ tone: "success", title: "Task completed", description: `“${title}”`, taskId });
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
  const queryClient = useQueryClient();

  useEffect(() => {
    if (!workspaceId || !token) return;

    const topic = `workspace:${workspaceId}`;
    const channel = joinChannel(topic);
    if (!channel) return;

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
        // The persisted message replaces the streamed draft, if any.
        useChatStore.getState().clearStreamingDraft(agentId);
        playSound("message");
      }
    });

    // Token-by-token reply stream: grow the agent's draft bubble live. The
    // final `agent_chat.message` broadcast swaps the draft for the real thing.
    const chatChunkRef = channel.on("agent_chat.chunk", (payload: EventPayload) => {
      const agentId = str(payload ?? {}, "agent_id");
      const streamId = str(payload ?? {}, "stream_id");
      if (!agentId || !streamId) return;
      const chunk = typeof payload.chunk === "string" ? payload.chunk : "";
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

    // Catch-up on reconnect: any event broadcast while the socket was down
    // (server restart, laptop sleep, network blip) was lost — refetch the
    // realtime-backed data so the UI never sits on a stale pipeline.
    let firstOpen = true;
    const offOpen = onSocketOpen(() => {
      if (!firstOpen) {
        invalidate([["tasks"], ["agents"], ["dashboard"], ["notifications"], ["analytics"]]);
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
      channel.off("agent_chat.typing", typingRef);
      channel.off("task.agent_typing", taskTypingRef);
      channel.off("task.comment_added", commentRef);
      channel.off("task.plan_updated", planRef);
    };
  }, [workspaceId, token, queryClient]);
}
