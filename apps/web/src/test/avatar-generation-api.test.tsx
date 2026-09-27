import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  useAvatarGeneration,
  useAvatarGenerations,
  useCreateAvatarGeneration,
} from "@/api/avatar-generations";
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

function wrapper(client = new QueryClient({ defaultOptions: { queries: { retry: false } } })) {
  return ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  );
}

describe("Avatar generation API integration", () => {
  it("exposes the authoritative quote and balance alongside saved generations", async () => {
    const meta = { pricing: { credits: 1250 }, credits: { spendable: 2400, unlimited: false } };
    fetchMock.mockResolvedValue(new Response(JSON.stringify({ data: [], meta }), { status: 200 }));
    const { result } = renderHook(() => useAvatarGenerations(), { wrapper: wrapper() });
    await waitFor(() => expect(result.current.pricing).toEqual(meta.pricing));
    expect(result.current.credits).toEqual(meta.credits);
    expect(result.current.data).toEqual([]);
  });

  it("invalidates credit balances after a generation request", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ data: { id: "job" } }), { status: 202 }),
    );
    const client = new QueryClient();
    const invalidate = vi.spyOn(client, "invalidateQueries");
    const { result } = renderHook(() => useCreateAvatarGeneration(), { wrapper: wrapper(client) });
    await act(async () => {
      await result.current.mutateAsync({
        mode: "text",
        prompt: "A designer",
        expected_credits: 1000,
      });
    });
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["billing"] });
    expect(invalidate).toHaveBeenCalledWith({ queryKey: ["avatar-generations"] });
  });

  it("refreshes balances and the quote when a failed job refunds its charge", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ data: { id: "job", status: "failed" } }), { status: 200 }),
    );
    const client = new QueryClient();
    const invalidate = vi.spyOn(client, "invalidateQueries");
    renderHook(() => useAvatarGeneration("job"), { wrapper: wrapper(client) });
    await waitFor(() => expect(invalidate).toHaveBeenCalledWith({ queryKey: ["billing"] }));
    expect(invalidate).toHaveBeenCalledWith({
      queryKey: ["avatar-generations", "workspace-one", "user-one"],
      exact: true,
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("sends photo bytes as multipart with workspace and cookie-session CSRF headers", async () => {
    fetchMock.mockResolvedValue(
      new Response(JSON.stringify({ data: { id: "job" } }), { status: 202 }),
    );
    const file = new File(["photo"], "person.png", { type: "image/png" });
    const { result } = renderHook(() => useCreateAvatarGeneration(), { wrapper: wrapper() });
    await act(async () => {
      await result.current.mutateAsync({
        mode: "image",
        file,
        name: "Nova",
        expected_credits: 1000,
      });
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
    expect(request.body.get("expected_credits")).toBe("1000");
  });

  it("never automatically repeats a failed paid text-generation request", async () => {
    fetchMock.mockResolvedValue(
      new Response(
        JSON.stringify({
          error: { message: "Character generation unavailable", code: "unavailable" },
        }),
        { status: 503 },
      ),
    );
    const { result } = renderHook(() => useCreateAvatarGeneration(), { wrapper: wrapper() });
    await act(async () => {
      await expect(
        result.current.mutateAsync({ mode: "text", prompt: "A designer", expected_credits: 1000 }),
      ).rejects.toThrow("Character generation unavailable");
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(JSON.parse(fetchMock.mock.calls[0][1].body)).toEqual({
      mode: "text",
      prompt: "A designer",
      expected_credits: 1000,
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
