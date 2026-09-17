import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { apiFetch, signOut } from "@/api/client";
import { browserCsrfToken, sessionHeaders } from "@/lib/browser-session";
import {
  googleIdentityVerifier,
  rememberGoogleIdentity,
  clearGoogleIdentity,
} from "@/lib/google-identity";
import { useAuthStore } from "@/stores/auth-store";

vi.mock("@/realtime/phoenix-client", () => ({ disconnect: vi.fn() }));
const user = { id: "user-one", email: "user@example.com", full_name: "User One", avatar_url: null };

beforeEach(() => {
  localStorage.clear();
  sessionStorage.clear();
  useAuthStore.setState({ token: null, user: null, workspaces: [], workspaceId: null });
});
afterEach(() => vi.unstubAllGlobals());

describe("cookie authentication", () => {
  it("persists only a CSRF marker and sends the credential exclusively as a cookie", async () => {
    useAuthStore.getState().setSession("private-bearer", user);
    expect(localStorage.getItem("mokaid-auth")).not.toContain("private-bearer");
    useAuthStore.getState().setSession("browser:csrf-value", user);
    expect(localStorage.getItem("mokaid-auth")).toContain("browser:csrf-value");
    expect(browserCsrfToken("browser:csrf-value")).toBe("csrf-value");
    expect(sessionHeaders("browser:csrf-value")).toEqual({ "x-csrf-token": "csrf-value" });
    const fetchMock = vi
      .fn()
      .mockResolvedValue(new Response(JSON.stringify({ user }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    await apiFetch("/api/me", { skipWorkspace: true });
    expect(fetchMock).toHaveBeenCalledWith(
      expect.any(URL),
      expect.objectContaining({
        credentials: "include",
        headers: { "Content-Type": "application/json", "x-csrf-token": "csrf-value" },
      }),
    );
  });

  it("an old unauthorized request cannot erase a newer account session", async () => {
    useAuthStore.getState().setSession("browser:old-csrf", user);
    let finish!: (response: Response) => void;
    vi.stubGlobal(
      "fetch",
      vi.fn().mockImplementation(
        () =>
          new Promise<Response>((resolve) => {
            finish = resolve;
          }),
      ),
    );
    const pending = apiFetch("/api/me");
    useAuthStore.getState().setSession("browser:new-csrf", { ...user, id: "new-user" });
    finish(new Response(JSON.stringify({ error: { code: "unauthorized" } }), { status: 401 }));
    await expect(pending).rejects.toThrow();
    expect(useAuthStore.getState().token).toBe("browser:new-csrf");
  });

  it("a failed login does not clear an existing session", async () => {
    useAuthStore.getState().setSession("browser:existing", user);
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response("{}", { status: 401 })));
    await expect(apiFetch("/api/auth/login", { method: "POST", body: {} })).rejects.toThrow();
    expect(useAuthStore.getState().token).toBe("browser:existing");
  });

  it("revokes remotely before clearing local state and preserves retry on a network failure", async () => {
    useAuthStore.getState().setSession("browser:csrf", user);
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    await expect(signOut()).rejects.toThrow("offline");
    expect(useAuthStore.getState().token).toBe("browser:csrf");
    const fetchMock = vi.fn().mockResolvedValue(new Response('{"ok":true}', { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);
    await signOut();
    expect(fetchMock.mock.calls[0][0].pathname).toBe("/api/auth/logout");
    expect(useAuthStore.getState().token).toBeNull();
  });

  it("clears the previous account's workspace before binding a new identity", () => {
    useAuthStore
      .getState()
      .establishSession("browser:one", user, [
        { id: "private-workspace", name: "Private", slug: "private", logo_url: null },
      ]);
    useAuthStore.getState().setSession("browser:two", { ...user, id: "user-two" });
    expect(useAuthStore.getState().workspaceId).toBeNull();
    expect(useAuthStore.getState().workspaces).toEqual([]);
  });
});

describe("Google identity binding", () => {
  const verifier = "v".repeat(43);
  it("rejects unsolicited or altered callbacks and only accepts the originating tab's state", () => {
    expect(() => googleIdentityVerifier("unsolicited")).toThrow();
    rememberGoogleIdentity(
      "https://accounts.google.com/o/oauth2/v2/auth?state=expected",
      verifier,
      "/account",
    );
    expect(googleIdentityVerifier("expected")).toBe(verifier);
    expect(() => googleIdentityVerifier("another-state")).toThrow();
    clearGoogleIdentity();
    expect(() => googleIdentityVerifier("expected")).toThrow();
  });

  it("rejects expired flows and non-Google authorization URLs", () => {
    vi.useFakeTimers();
    rememberGoogleIdentity(
      "https://accounts.google.com/o/oauth2/v2/auth?state=expected",
      verifier,
      "/account",
    );
    vi.advanceTimersByTime(600_001);
    expect(() => googleIdentityVerifier("expected")).toThrow();
    vi.useRealTimers();
    expect(() =>
      rememberGoogleIdentity("https://evil.example/?state=expected", verifier, "/account"),
    ).toThrow();
  });
});
