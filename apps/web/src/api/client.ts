import { sessionHeaders } from "@/lib/browser-session";
import { disconnect } from "@/realtime/phoenix-client";
import { resolveApiUrl } from "@/lib/env";
import { useAuthStore } from "@/stores/auth-store";

export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: unknown,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

interface RequestOptions {
  method?: "GET" | "POST" | "PATCH" | "PUT" | "DELETE";
  body?: unknown;
  params?: Record<string, string | undefined>;
  skipWorkspace?: boolean;
}

export async function apiFetch<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const { token, workspaceId } = useAuthStore.getState();

  const url = resolveApiUrl(path);
  if (options.params) {
    for (const [key, value] of Object.entries(options.params)) {
      if (value != null && value !== "") url.searchParams.set(key, value);
    }
  }

  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...sessionHeaders(token),
  };
  if (workspaceId && !options.skipWorkspace) headers["x-workspace-id"] = workspaceId;

  const response = await fetch(url, {
    method: options.method ?? "GET",
    credentials: "include",
    headers,
    body: options.body != null ? JSON.stringify(options.body) : undefined,
  });

  // A delayed rejection from a previous account must never erase a newer session.
  if (
    response.status === 401 &&
    token &&
    useAuthStore.getState().token === token &&
    !path.startsWith("/api/auth/")
  ) {
    disconnect();
    useAuthStore.getState().logout();
  }

  const payload = await response.json().catch(() => null);

  if (!response.ok) {
    const error = payload?.error ?? {};
    throw new ApiError(
      response.status,
      error.code ?? "unknown",
      error.message ?? `Request failed with ${response.status}`,
      error.details,
    );
  }

  return payload as T;
}

/** Multipart upload (files). Content-Type is set automatically by the browser. */
export async function apiUpload<T>(path: string, formData: FormData): Promise<T> {
  const { token, workspaceId } = useAuthStore.getState();

  const headers = sessionHeaders(token);
  if (workspaceId) headers["x-workspace-id"] = workspaceId;

  const response = await fetch(resolveApiUrl(path), {
    method: "POST",
    credentials: "include",
    headers,
    body: formData,
  });

  if (response.status === 401 && token && useAuthStore.getState().token === token) {
    disconnect();
    useAuthStore.getState().logout();
  }

  const payload = await response.json().catch(() => null);

  if (!response.ok) {
    const error = payload?.error ?? {};
    throw new ApiError(
      response.status,
      error.code ?? "unknown",
      error.message ?? `Upload failed with ${response.status}`,
      error.details,
    );
  }

  return payload as T;
}

/**
 * Fetch a drive file's bytes through the authenticated API proxy.
 * Same-origin (the API), so it works even when the browser can't reach the
 * object store directly (HSTS upgrades, blocked ports, prod networking).
 */
export async function fetchDriveFileBlob(fileId: string): Promise<Blob> {
  const { token, workspaceId } = useAuthStore.getState();

  const headers = sessionHeaders(token);
  if (workspaceId) headers["x-workspace-id"] = workspaceId;

  const response = await fetch(resolveApiUrl(`/api/drive/${fileId}/raw`), {
    headers,
    credentials: "include",
  });

  if (response.status === 401 && token && useAuthStore.getState().token === token) {
    disconnect();
    useAuthStore.getState().logout();
  }
  if (!response.ok) {
    throw new ApiError(
      response.status,
      "download_failed",
      `Download failed with ${response.status}`,
    );
  }

  return response.blob();
}

/** Fetch workspace logo bytes through the authenticated API proxy. */
export async function fetchWorkspaceLogoBlob(workspaceId: string): Promise<Blob | null> {
  const { token, workspaceId: activeWorkspaceId } = useAuthStore.getState();
  if (!token) return null;

  const response = await fetch(resolveApiUrl(`/api/workspaces/${workspaceId}/logo`), {
    credentials: "include",
    headers: {
      ...sessionHeaders(token),
      "x-workspace-id": activeWorkspaceId ?? workspaceId,
    },
  });

  if (!response.ok) return null;
  return response.blob();
}

/** Revoke the server session before removing the local account state. */
export async function signOut(): Promise<void> {
  const token = useAuthStore.getState().token;
  await apiFetch("/api/auth/logout", { method: "POST", body: {}, skipWorkspace: true });
  if (useAuthStore.getState().token === token) {
    disconnect();
    useAuthStore.getState().logout();
  }
}
