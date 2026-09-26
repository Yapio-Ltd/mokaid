import { useMutation, useQueryClient } from "@tanstack/react-query";
import { apiFetch } from "./client";
import type { Envelope } from "./types";
import { useAuthStore } from "@/stores/auth-store";

/** Answer an actual pending external action or delivery question. PDF exports never use this. */
export function useTaskActionDecision() {
  const queryClient = useQueryClient();
  const workspaceId = useAuthStore((state) => state.workspaceId);
  return useMutation({
    mutationFn: ({
      taskId,
      requestId,
      decision,
      payload,
    }: {
      taskId: string;
      requestId: string;
      decision: "approved" | "rejected" | "edited";
      payload?: { delivery: "html" | "webapp" };
    }) =>
      apiFetch<Envelope<{ id: string; status: string }>>(`/api/tasks/${taskId}/approve-action`, {
        method: "POST",
        body: { approval_request_id: requestId, decision, ...(payload ? { payload } : {}) },
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["tasks", workspaceId] });
      queryClient.invalidateQueries({ queryKey: ["agents", workspaceId] });
      queryClient.invalidateQueries({ queryKey: ["notifications", workspaceId] });
    },
    retry: false,
  });
}
