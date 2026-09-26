import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useAvatarGenerations, useCreateAvatarGeneration } from "@/api/avatar-generations";
import { useAuthStore } from "@/stores/auth-store";

const fetchMock = vi.fn();
beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  fetchMock.mockReset();
  useAuthStore.setState({
    token: "browser:test-csrf",
    workspaceId: "workspace-one",
    user: { id: "user-one", full_name: "Test", email: "test@example.test", avatar_url: null },
  });
});
afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

function wrapper() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  );
}

describe("Avatar generation API integration", () => {
  it("sends photo bytes as multipart with workspace and cookie-session CSRF headers", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ data: { id: "job" } }), { status: 202 }),
    );
    const file = new File(["photo"], "person.png", { type: "image/png" });
    const { result } = renderHook(() => useCreateAvatarGeneration(), { wrapper: wrapper() });
    await act(async () => {
      await result.current.mutateAsync({ mode: "image", file, name: "Nova" });
    });
    const [url, request] = fetchMock.mock.calls[0];
    expect(new URL(url).pathname).toBe("/api/avatar-generations");
    expect(request.headers).toMatchObject({
      "x-workspace-id": "workspace-one",
      "x-csrf-token": "test-csrf",
    });
    expect(request.headers["Content-Type"]).toBeUndefined();
    expect(request.credentials).toBe("include");
    expect(request.body.get("file")).toBe(file);
    expect(request.body.get("mode")).toBe("image");
    expect(request.body.get("name")).toBe("Nova");
  });

  it("never automatically repeats a failed paid text-generation request", async () => {
    fetchMock.mockResolvedValue(
      new Response(
        JSON.stringify({ error: { message: "Meshy unavailable", code: "unavailable" } }),
        { status: 503 },
      ),
    );
    const { result } = renderHook(() => useCreateAvatarGeneration(), { wrapper: wrapper() });
    await act(async () => {
      await expect(
        result.current.mutateAsync({ mode: "text", prompt: "A designer" }),
      ).rejects.toThrow("Meshy unavailable");
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
      mode: "text",
      prompt: "A designer",
    });
  });

  it("fetches a fresh history when the workspace changes", async () => {
    fetchMock.mockImplementation(
      async (_url, request) =>
        new Response(
          JSON.stringify({ data: [{ id: request.headers["x-workspace-id"], status: "ready" }] }),
          { status: 200 },
        ),
    );
    const { result } = renderHook(() => useAvatarGenerations(), { wrapper: wrapper() });
    await waitFor(() => expect(result.current.data?.[0].id).toBe("workspace-one"));
    act(() => {
      useAuthStore.setState({ workspaceId: "workspace-two" });
    });
    await waitFor(() => expect(result.current.data?.[0].id).toBe("workspace-two"));
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
