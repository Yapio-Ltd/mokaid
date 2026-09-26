import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { ManagedRuntimePolicy } from "@mokaid/shared-types";
import { apiFetch } from "./client";
import { useAuthStore } from "@/stores/auth-store";

export interface RuntimePolicyResponse {
  data: ManagedRuntimePolicy;
  meta?: { can_update?: boolean };
}

export function useRuntimePolicy() {
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const userId = useAuthStore((state) => state.user?.id);
  return useQuery({
    queryKey: ["runtime-policy", workspaceId, userId],
    enabled: Boolean(workspaceId),
    retry: false,
    queryFn: () => {
      if (useAuthStore.getState().workspaceId !== workspaceId)
        throw new Error("The workspace changed. Please reload its settings.");
      return apiFetch<RuntimePolicyResponse>("/api/ai/runtime-policy");
    },
  });
}

export function useUpdateRuntimePolicy() {
  const client = useQueryClient();
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const userId = useAuthStore((state) => state.user?.id);
  return useMutation({
    mutationFn: (body: Pick<ManagedRuntimePolicy, "enabled" | "data_policy_accepted">) => {
      if (useAuthStore.getState().workspaceId !== workspaceId)
        throw new Error("The workspace changed. Please reload its settings.");
      return apiFetch<RuntimePolicyResponse>("/api/ai/runtime-policy", { method: "PATCH", body });
    },
    onSuccess: (data) => {
      client.setQueryData(["runtime-policy", workspaceId, userId], data);
    },
  });
}
