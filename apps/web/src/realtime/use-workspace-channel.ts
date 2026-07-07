import { useEffect } from "react";
import type { QueryClient } from "@tanstack/react-query";
import { useQueryClient } from "@tanstack/react-query";
import type { AgentChatMessage, BillingOverview, Envelope } from "@/api/types";
import { useAuthStore } from "@/stores/auth-store";
import { toast } from "@/stores/toast-store";
import { useUiStore } from "@/stores/ui-store";
import { useChatStore } from "@/stores/chat-store";
import { playSound } from "@/lib/sounds";
import { joinChannel, leaveChannel, onSocketOpen } from "./phoenix-client";

type EventPayload = Record<string, unknown>;

/** Inserts a chat message into the cached thread + summary — no refetch. */
function insertChatMessage(
  queryClient: QueryClient,
  workspaceId: string,
  agentId: string,
  message: AgentChatMessage,
): void {
  // Thread cache: ["agent-chat", workspaceId, agentId]
  queryClient.setQueryData<Envelope<AgentChatMessage[]>>(
    ["agent-chat", workspaceId, agentId],
    (prev) => {
      if (!prev) return prev;
      if (prev.data.some((m) => m.id === message.id)) return prev; // dedupe
      return { ...prev, data: [...prev.data, message] };
    },
  );
  // Summaries (last message + unread badge) refresh cheaply.
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
        playSound("message");
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
      bindings.forEach(([event], index) => channel.off(event, refs[index]));
      channel.off("agent_chat.message", chatMsgRef);
      channel.off("credits.updated", creditsRef);
      channel.off("agent_chat.typing", typingRef);
      leaveChannel(topic);
    };
  }, [workspaceId, token, queryClient]);
}
