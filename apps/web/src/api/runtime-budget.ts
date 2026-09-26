import { useMutation, useQueryClient } from "@tanstack/react-query";
import { apiFetch } from "./client";
import type { Envelope } from "./types";
import { useAuthStore } from "@/stores/auth-store";

export function useExtendRuntimeBudget() {
  const queryClient = useQueryClient();
  const workspaceId = useAuthStore((state) => state.workspaceId);
  return useMutation({
    mutationFn: ({
      taskId,
      ...body
    }: {
      taskId: string;
      run_id: string;
      request_id: string;
      additional_credits: 500 | 2000;
    }) => {
      if (useAuthStore.getState().workspaceId !== workspaceId)
        throw new Error("The workspace changed. Reopen this task before continuing.");
      return apiFetch<
        Envelope<{
          run_id: string;
          reserved_credits: number;
          budget_revision: number;
          status: "running";
        }>
      >(`/api/tasks/${taskId}/runtime-budget`, { method: "POST", body });
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["tasks", workspaceId] });
      void queryClient.invalidateQueries({ queryKey: ["agents", workspaceId] });
      void queryClient.invalidateQueries({ queryKey: ["billing", workspaceId] });
    },
    retry: false,
  });
}
