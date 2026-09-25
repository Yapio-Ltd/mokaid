import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useAuthStore } from "@/stores/auth-store";
import { apiFetch, apiUpload } from "./client";
import type { Asset3d } from "./hooks";
import type { Envelope } from "./types";

export type AvatarGenerationStatus =
  "queued" | "generating" | "texturing" | "rigging" | "saving" | "ready" | "failed";
export interface AvatarGeneration {
  id: string;
  mode: "image" | "text";
  name: string;
  status: AvatarGenerationStatus;
  progress: number;
  asset_id: string | null;
  asset: Asset3d | null;
  error: string | null;
  thumbnail_url: string | null;
  inserted_at: string;
  updated_at: string;
}

export type CreateAvatarGeneration =
  { mode: "image"; file: File; name?: string } | { mode: "text"; prompt: string; name?: string };
export const AVATAR_PHOTO_MAX_BYTES = 10_000_000;
export const AVATAR_PROMPT_MAX_LENGTH = 600;
export const avatarGenerationIsActive = (generation: AvatarGeneration) =>
  generation.status !== "ready" && generation.status !== "failed";

export function validateAvatarPhoto(file: File): string | null {
  if (!["image/jpeg", "image/png"].includes(file.type))
    return "Choose a JPG or PNG photo.";
  if (file.size === 0) return "This photo is empty. Choose another file.";
  if (file.size > AVATAR_PHOTO_MAX_BYTES)
    return "This photo is too large. Choose a file under 10 MB.";
  return null;
}

export function useAvatarGenerations() {
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const userId = useAuthStore((state) => state.user?.id);
  return useQuery({
    queryKey: ["avatar-generations", workspaceId, userId],
    enabled: Boolean(workspaceId && userId),
    queryFn: () =>
      apiFetch<Envelope<AvatarGeneration[]>>("/api/avatar-generations").then(
        (result) => result.data,
      ),
    refetchInterval: (query) => (query.state.data?.some(avatarGenerationIsActive) ? 5_000 : false),
    retry: 1,
  });
}

export function useAvatarGeneration(id: string | null) {
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const userId = useAuthStore((state) => state.user?.id);
  return useQuery({
    queryKey: ["avatar-generations", workspaceId, userId, id],
    enabled: Boolean(id && workspaceId && userId),
    queryFn: () =>
      apiFetch<Envelope<AvatarGeneration>>(`/api/avatar-generations/${id}`).then(
        (result) => result.data,
      ),
    refetchInterval: (query) =>
      query.state.data && !avatarGenerationIsActive(query.state.data) ? false : 3_000,
    retry: 1,
  });
}

export function useCreateAvatarGeneration() {
  const client = useQueryClient();
  return useMutation({
    mutationFn: (input: CreateAvatarGeneration) => {
      if (input.mode === "image") {
        const body = new FormData();
        body.append("mode", "image");
        body.append("file", input.file);
        if (input.name) body.append("name", input.name);
        return apiUpload<Envelope<AvatarGeneration>>("/api/avatar-generations", body).then(
          (result) => result.data,
        );
      }
      return apiFetch<Envelope<AvatarGeneration>>("/api/avatar-generations", {
        method: "POST",
        body: input,
      }).then((result) => result.data);
    },
    // Never automatically repeat a paid generation request after a lost response.
    retry: false,
    onSettled: () => client.invalidateQueries({ queryKey: ["avatar-generations"] }),
  });
}
