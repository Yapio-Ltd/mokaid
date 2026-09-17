import { createMemoryHistory } from "@tanstack/react-router";
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("@/pages/landing", () => ({ LandingPage: () => null }));
vi.mock("@/pages/login", () => ({ LoginPage: () => null }));
vi.mock("@/pages/signup", () => ({ SignupPage: () => null }));
vi.mock("@/api/client", () => ({
  apiFetch: vi.fn().mockResolvedValue({ client_policy: { desktop_only_business: false } }),
}));

async function loadRoute(
  path: string,
  { signedIn = false, desktopOnly = true, serverDesktopOnly = false } = {},
) {
  vi.resetModules();
  vi.stubEnv("VITE_DESKTOP_ONLY_WEB", String(desktopOnly));
  const { useAuthStore } = await import("@/stores/auth-store");
  const { apiFetch } = await import("@/api/client");
  vi.mocked(apiFetch).mockResolvedValue({
    client_policy: { desktop_only_business: serverDesktopOnly },
  });
  useAuthStore.setState({
    token: signedIn ? "test-session" : null,
    user: signedIn
      ? { id: "test-user", email: "test@example.invalid", full_name: "Test", avatar_url: null }
      : null,
  });
  const { router } = await import("@/router");
  router.update({ history: createMemoryHistory({ initialEntries: [path] }) });
  await router.load();
  return router;
}

afterEach(() => {
  vi.unstubAllEnvs();
  localStorage.clear();
});

describe("account-only route integration", () => {
  it("keeps marketing home reachable even when signed in", async () => {
    const router = await loadRoute("/", { signedIn: true });
    expect(router.state.location.pathname).toBe("/");
  });

  it("returns unauthenticated direct account links to login with a safe continuation", async () => {
    const router = await loadRoute("/account/invoices");
    expect(router.state.location.pathname).toBe("/login");
    expect(router.state.location.search).toEqual({ returnTo: "/account/invoices" });
  });

  it.each([
    "/dashboard",
    "/agents/new",
    "/agents/a/training",
    "/calendar",
    "/projects",
    "/integrations",
  ])("redirects retired experience deep link %s without mounting the app", async (path) => {
    const router = await loadRoute(path);
    expect(router.state.location.pathname).toBe("/download");
    expect(router.state.matches.some((match) => match.routeId === "/app")).toBe(false);
  });

  it("preserves Stripe return state through the billing compatibility route", async () => {
    const router = await loadRoute("/billing?checkout=success&token=private", { signedIn: true });
    expect(router.state.location.pathname).toBe("/account/billing");
    expect(router.state.location.search).toEqual({ checkout: "success" });
  });

  it("returns signed-in login links to desktop consent, not to the office", async () => {
    const id = "11111111-2222-4333-8444-555555555555";
    const router = await loadRoute(
      `/login?returnTo=${encodeURIComponent(`/desktop/authorize?request_id=${id}`)}`,
      { signedIn: true },
    );
    expect(router.state.location.pathname).toBe("/desktop/authorize");
    expect(router.state.location.search).toEqual({ request_id: id });
  });

  it.each([
    "/oauth/google/callback?code=one&state=two",
    "/auth/google/callback?code=one&state=two",
    "/desktop/authorize?request_id=one",
  ])("preserves root callback route %s", async (path) => {
    const router = await loadRoute(path);
    expect(router.state.location.pathname).toBe(path.split("?")[0]);
  });

  it("cannot restore the Office with the old rollout flag disabled", async () => {
    const router = await loadRoute("/dashboard", { signedIn: true, desktopOnly: false });
    expect(router.state.location.pathname).toBe("/download");
  });

  it("keeps signed-in visitors on the landing with the old rollout flag disabled", async () => {
    const router = await loadRoute("/", { signedIn: true, desktopOnly: false });
    expect(router.state.location.pathname).toBe("/");
  });

  it("sends an ordinary signed-in login to the account", async () => {
    const router = await loadRoute("/login", { signedIn: true, desktopOnly: false });
    expect(router.state.location.pathname).toBe("/account");
  });

  it("honors server policy before mounting business in an older build", async () => {
    const router = await loadRoute("/dashboard", {
      signedIn: true,
      desktopOnly: false,
      serverDesktopOnly: true,
    });
    expect(router.state.location.pathname).toBe("/download");
  });
});
