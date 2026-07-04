import { env } from "@/lib/env";
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

  const url = new URL(`${env.VITE_API_URL}${path}`);
  if (options.params) {
    for (const [key, value] of Object.entries(options.params)) {
      if (value != null && value !== "") url.searchParams.set(key, value);
    }
  }

  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (workspaceId && !options.skipWorkspace) headers["x-workspace-id"] = workspaceId;

  const response = await fetch(url, {
    method: options.method ?? "GET",
    headers,
    body: options.body != null ? JSON.stringify(options.body) : undefined,
  });

  if (response.status === 401) {
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
