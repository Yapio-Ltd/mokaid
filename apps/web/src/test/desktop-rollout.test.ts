import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ACCOUNT_LINKS,
  accountEntryPath,
  authReturnFromSearch,
  legacyAccountDestination,
  localNavigation,
  safeAuthReturn,
} from "@/lib/desktop-rollout";
import { disposeOfficeIfLoaded, registerOfficeCleanup } from "@/lib/office-lifecycle";
import { useAuthStore } from "@/stores/auth-store";

afterEach(() => vi.restoreAllMocks());

describe("desktop-only navigation policy", () => {
  it("keeps the current experience until rollout is explicitly enabled", () => {
    expect(accountEntryPath(false)).toBe("/dashboard");
    expect(accountEntryPath(true)).toBe("/account");
    expect(safeAuthReturn("/agents/agent-1/training", false)).toBe("/agents/agent-1/training");
    expect(safeAuthReturn("/agents/agent-1/training", true)).toBe("/download");
  });

  it("allows only account/billing sections and downloads in portal navigation", () => {
    expect(ACCOUNT_LINKS.map((link) => link.path)).toEqual([
      "/account",
      "/account/profile",
      "/account/security",
      "/account/billing",
      "/account/plans",
      "/account/usage",
      "/account/spending",
      "/account/invoices",
    ]);
    for (const { path } of ACCOUNT_LINKS) expect(safeAuthReturn(path, true)).toBe(path);
    expect(legacyAccountDestination("/settings")).toBe("/account/profile");
    expect(legacyAccountDestination("/profile")).toBe("/account/profile");
  });

  it("preserves verified desktop consent transactions through sign-in", () => {
    const path = "/desktop/authorize?request_id=11111111-2222-4333-8444-555555555555";
    expect(authReturnFromSearch(`?returnTo=${encodeURIComponent(path)}`, true)).toBe(path);
    expect(safeAuthReturn(`${path}&token=secret`, true)).toBe(path);
    expect(safeAuthReturn("/desktop/authorize?request_id=bad", true)).toBe("/account");
  });

  it("preserves payment outcomes, discarding credentials and unknown query fields", () => {
    expect(
      legacyAccountDestination("/billing", "?checkout=success&token=private&customer=alice"),
    ).toBe("/account/billing?checkout=success");
    expect(legacyAccountDestination("/billing", "?payment=done")).toBe(
      "/account/billing?payment=done",
    );
    expect(safeAuthReturn("/billing?checkout=canceled", true)).toBe(
      "/account/billing?checkout=canceled",
    );
    expect(safeAuthReturn("/account/spending?checkout=success&token=private", true)).toBe(
      "/account/spending?checkout=success",
    );
    expect(localNavigation("/account/billing?checkout=success")).toEqual({
      to: "/account/billing",
      search: { checkout: "success" },
    });
  });

  it.each([
    "https://evil.test",
    "//evil.test",
    "/\\evil.test",
    "/\n/evil.test",
    "/%2f%2fevil.test",
    "/login?returnTo=/login",
    "/oauth/google/callback?code=secret",
    "/account/unknown",
    "/desktop/authorize?request_id=bad",
  ])("rejects unsafe or unknown return target %s", (target) => {
    expect(safeAuthReturn(target, true)).toBe("/account");
  });
});

describe("renderer-free account lifecycle", () => {
  it("logout and workspace changes only dispose a renderer already registered", () => {
    const renderer = vi.fn();
    disposeOfficeIfLoaded();
    const unregister = registerOfficeCleanup(renderer);
    useAuthStore.setState({ workspaceId: "one" });
    useAuthStore.getState().selectWorkspace("two");
    expect(renderer).toHaveBeenCalledTimes(1);
    useAuthStore.getState().logout();
    expect(renderer).toHaveBeenCalledTimes(2);
    unregister();
    useAuthStore.getState().logout();
    expect(renderer).toHaveBeenCalledTimes(2);
  });

  it("an old renderer registration cannot remove its replacement", () => {
    const oldRenderer = vi.fn();
    const newRenderer = vi.fn();
    const unregisterOld = registerOfficeCleanup(oldRenderer);
    const unregisterNew = registerOfficeCleanup(newRenderer);
    unregisterOld();
    disposeOfficeIfLoaded();
    expect(newRenderer).toHaveBeenCalledOnce();
    expect(oldRenderer).not.toHaveBeenCalled();
    unregisterNew();
  });
});
