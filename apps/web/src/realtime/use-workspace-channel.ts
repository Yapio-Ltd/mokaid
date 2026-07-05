import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useAuthStore } from "@/stores/auth-store";
import { toast } from "@/stores/toast-store";
import { joinChannel, leaveChannel } from "./phoenix-client";

type EventPayload = Record<string, unknown>;

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
        toast({
          tone: "success",
          title: "Ready for review",
          description: `"${title}": the agent finished. Check the output.`,
          taskId,
          duration: 8000,
        });
      } else if (status === "failed") {
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
    ];

    const refs = bindings.map(([event, keys]) =>
      channel.on(event, (payload: EventPayload) => {
        invalidate(keys);
        maybeToast(event, payload ?? {});
      }),
    );

    return () => {
      bindings.forEach(([event], index) => channel.off(event, refs[index]));
      leaveChannel(topic);
    };
  }, [workspaceId, token, queryClient]);
}
