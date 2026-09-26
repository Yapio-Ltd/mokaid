import { useMutation, useQueryClient } from "@tanstack/react-query";
import type { TaskResponseFeedbackInput } from "@mokaid/shared-types";
import { apiFetch } from "./client";
import type { Envelope, Task } from "./types";
import { useAuthStore } from "@/stores/auth-store";
import { useTaskFeedbackStore } from "@/stores/task-feedback-store";

export function useTaskResponseFeedback() {
  const queryClient = useQueryClient();
  const workspaceId = useAuthStore((state) => state.workspaceId);

  return useMutation({
    mutationFn: ({ taskId, ...body }: TaskResponseFeedbackInput & { taskId: string }) =>
      apiFetch<Envelope<Task>>(`/api/tasks/${taskId}/feedback`, { method: "POST", body }),
    onSuccess: (result, variables) => {
      useTaskFeedbackStore
        .getState()
        .clearDraft(`${workspaceId}:${variables.taskId}:${variables.run_id ?? "no-run"}`);
      queryClient.setQueryData(["tasks", workspaceId, "detail", variables.taskId], result);
      queryClient.invalidateQueries({ queryKey: ["tasks", workspaceId] });
      queryClient.invalidateQueries({ queryKey: ["agents", workspaceId] });
      queryClient.invalidateQueries({ queryKey: ["notifications", workspaceId] });
    },
    // A failed continuation must never start a second run automatically.
    retry: false,
  });
}
