import { useEffect } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { useAuthStore } from "@/stores/auth-store";
import { joinChannel, leaveChannel } from "./phoenix-client";

/**
 * Joins the workspace channel and invalidates the relevant queries when
 * compact realtime events arrive. Details are refetched — payloads stay small.
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
      channel.on(event, () => invalidate(keys)),
    );

    return () => {
      bindings.forEach(([event], index) => channel.off(event, refs[index]));
      leaveChannel(topic);
    };
  }, [workspaceId, token, queryClient]);
}
