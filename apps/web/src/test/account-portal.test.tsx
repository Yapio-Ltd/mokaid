import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { AccountShell } from "@/components/account/account-shell";
import { AccountBillingPage, invoiceDocument } from "@/pages/account-billing";
import { GoogleSignInButton } from "@/components/auth/google-sign-in-button";
import { useAuthStore } from "@/stores/auth-store";
import { ACCOUNT_LINKS } from "@/lib/desktop-rollout";
import { LoginPage } from "@/pages/login";
import { SignupPage } from "@/pages/signup";
import { GoogleAuthCallbackPage } from "@/pages/google-auth-callback";

const mock = vi.hoisted(() => ({ apiFetch: vi.fn(), navigate: vi.fn(), pathname: "/account" }));
vi.mock("@/api/client", async (original) => ({
  ...(await original<typeof import("@/api/client")>()),
  apiFetch: mock.apiFetch,
}));
vi.mock("@tanstack/react-router", () => ({
  Link: ({
    to,
    children,
    className,
    "aria-current": current,
  }: {
    to: string;
    children: ReactNode;
    className?: string;
    "aria-current"?: "page";
  }) => (
    <a href={to} className={className} aria-current={current}>
      {children}
    </a>
  ),
  useNavigate: () => mock.navigate,
  useRouterState: ({
    select,
  }: {
    select: (state: { location: { pathname: string } }) => unknown;
  }) => select({ location: { pathname: mock.pathname } }),
  Outlet: () => <p>Account content</p>,
}));
vi.mock("@/three/office-scene-host", () => {
  throw new Error("Account portal must not import the renderer");
});
vi.mock("@/realtime/use-workspace-channel", () => {
  throw new Error("Account portal must not import workspace Channels");
});
vi.mock("gsap", () => ({ default: { context: () => ({ revert: () => undefined }) } }));

const user = {
  id: "user",
  full_name: "Ada",
  email: "ada@example.invalid",
  avatar_url: null,
  has_password: true,
};
const workspaces = [
  { id: "one", name: "First team", slug: "first", logo_url: null },
  { id: "two", name: "Second team", slug: "second", logo_url: null },
];
const overview = {
  subscription: {
    id: "subscription",
    status: "active",
    billing_cycle: "monthly",
    current_period_start: "2026-09-01",
    current_period_end: "2026-10-01",
    payment_method: {},
    credits_balance: 100,
    plan: {
      key: "starter",
      name: "Starter",
      price_cents_monthly: 4900,
      price_cents_yearly: 49000,
      limits: {},
      features: [],
    },
  },
  credits: {
    included_remaining: 90,
    balance: 10,
    spendable: 100,
    monthly_credits: 100,
    unlimited: false,
  },
  usage: [
    { event_type: "ai_request", total_quantity: "12", total_cost_cents: 120, unit: "request" },
  ],
  daily_usage: [{ day: "2026-09-12", event_type: "ai_request", total: "12" }],
  credit_transactions: [
    {
      id: "transaction",
      kind: "spend",
      amount: -12,
      cost_cents: 120,
      balance_after: 100,
      description: "AI request",
      inserted_at: "2026-09-12",
    },
  ],
};
const clients: QueryClient[] = [];

function renderWithQueries(component: ReactNode) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  });
  clients.push(client);
  return render(<QueryClientProvider client={client}>{component}</QueryClientProvider>);
}

beforeEach(() => {
  mock.pathname = "/account";
  mock.navigate.mockReset();
  mock.apiFetch.mockReset().mockImplementation(async (path: string) => {
    if (path === "/api/me") return { user, workspaces };
    if (path === "/api/billing/overview") return { data: overview };
    if (path === "/api/billing/plans")
      return { data: [{ ...overview.subscription.plan, key: "team", name: "Team" }] };
    if (path === "/api/billing/credit-packs")
      return { data: [{ key: "small", credits: 1000, price_cents: 1000 }] };
    if (path === "/api/billing/invoices") return { data: [] };
    if (path === "/api/billing/checkout") return { data: { activated: true } };
    throw new Error(`Unexpected request ${path}`);
  });
  useAuthStore.setState({ token: "test-session", user, workspaceId: "one", workspaces });
  window.history.replaceState({}, "", "/account");
});

afterEach(() => {
  cleanup();
  clients.splice(0).forEach((client) => client.clear());
  sessionStorage.clear();
});

describe("account-only shell", () => {
  it("shows only account links and downloads, with no business request on workspace switch or logout", async () => {
    renderWithQueries(<AccountShell />);
    await screen.findByText("Account content");
    const navigation = screen.getByRole("navigation", { name: "Account" });
    expect([...navigation.querySelectorAll("a")].map((link) => link.getAttribute("href"))).toEqual(
      ACCOUNT_LINKS.map((link) => link.path),
    );
    expect(screen.getByRole("link", { name: "Download desktop" })).toHaveAttribute(
      "href",
      "/download",
    );
    fireEvent.change(screen.getByLabelText("Billing workspace"), { target: { value: "two" } });
    await waitFor(() => expect(useAuthStore.getState().workspaceId).toBe("two"));
    fireEvent.click(screen.getByRole("button", { name: "Sign out" }));
    await waitFor(() => expect(useAuthStore.getState().token).toBeNull());
    expect(mock.apiFetch.mock.calls.every(([path]) => path === "/api/me")).toBe(true);
    expect(mock.navigate).toHaveBeenCalledWith(expect.objectContaining({ to: "/login" }));
  });

  it("shows a recoverable error rather than mounting private data after /me fails", async () => {
    mock.apiFetch.mockRejectedValue(new Error("offline"));
    renderWithQueries(<AccountShell />);
    expect(await screen.findByRole("alert")).toHaveTextContent("could not load your account");
    expect(screen.queryByText("Account content")).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument();
  });
});

describe("account billing", () => {
  it.each([
    ["billing", "Current plan"],
    ["plans", "Plans"],
    ["usage", "Usage this billing period"],
    ["spending", "Recent credit transactions"],
    ["invoices", "No invoices yet."],
  ])("uses real allowed billing data for /account/%s", async (section, text) => {
    mock.pathname = `/account/${section}`;
    renderWithQueries(<AccountBillingPage />);
    expect(await screen.findByText(text, { exact: true })).toBeInTheDocument();
    expect(
      mock.apiFetch.mock.calls.every(([path]) => String(path).startsWith("/api/billing/")),
    ).toBe(true);
  });

  it("returns a completed plan checkout to account billing", async () => {
    mock.pathname = "/account/plans";
    renderWithQueries(<AccountBillingPage />);
    fireEvent.click(await screen.findByRole("button", { name: "Choose" }));
    await waitFor(() =>
      expect(mock.apiFetch).toHaveBeenCalledWith(
        "/api/billing/checkout",
        expect.objectContaining({
          body: expect.objectContaining({ return_path: "/account/billing" }),
        }),
      ),
    );
  });

  it("allows changing the current monthly plan to the same plan billed yearly", async () => {
    mock.pathname = "/account/plans";
    const original = mock.apiFetch.getMockImplementation();
    mock.apiFetch.mockImplementation(async (path: string, options: unknown) => {
      if (path === "/api/billing/plans") return { data: [overview.subscription.plan] };
      return original?.(path, options);
    });
    renderWithQueries(<AccountBillingPage />);
    expect(await screen.findByRole("button", { name: "Current plan" })).toBeDisabled();
    fireEvent.click(screen.getByRole("button", { name: /Yearly/ }));
    fireEvent.click(screen.getByRole("button", { name: "Choose" }));
    await waitFor(() =>
      expect(mock.apiFetch).toHaveBeenCalledWith(
        "/api/billing/checkout",
        expect.objectContaining({
          body: { plan_key: "starter", billing_cycle: "yearly", return_path: "/account/billing" },
        }),
      ),
    );
  });

  it("starts on the subscription cycle and keeps an explicit choice after a refresh", async () => {
    mock.pathname = "/account/plans";
    const original = mock.apiFetch.getMockImplementation();
    mock.apiFetch.mockImplementation(async (path: string, options: unknown) => {
      if (path === "/api/billing/overview")
        return {
          data: {
            ...overview,
            subscription: { ...overview.subscription, billing_cycle: "yearly" },
          },
        };
      if (path === "/api/billing/plans") return { data: [overview.subscription.plan] };
      return original?.(path, options);
    });
    renderWithQueries(<AccountBillingPage />);
    expect(await screen.findByRole("button", { name: "Current plan" })).toBeDisabled();
    expect(screen.getByText(/billed yearly/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Monthly" }));
    expect(screen.getByRole("button", { name: "Choose" })).toBeEnabled();
    await act(async () => {
      await clients[clients.length - 1].invalidateQueries({ queryKey: ["billing"] });
    });
    expect(screen.getByRole("button", { name: "Choose" })).toBeEnabled();
    expect(screen.queryByText(/billed yearly/)).not.toBeInTheDocument();
  });

  it("keeps invoices available when the separate billing overview fails", async () => {
    mock.pathname = "/account/invoices";
    const original = mock.apiFetch.getMockImplementation();
    mock.apiFetch.mockImplementation(async (path: string, options: unknown) => {
      if (path === "/api/billing/overview") throw new Error("Overview is unavailable");
      return original?.(path, options);
    });
    renderWithQueries(<AccountBillingPage />);
    expect(await screen.findByText("No invoices yet.")).toBeInTheDocument();
    expect(screen.queryByText("Overview is unavailable")).not.toBeInTheDocument();
  });

  it("explains unavailable credit packs without hiding recorded spending", async () => {
    mock.pathname = "/account/spending";
    const original = mock.apiFetch.getMockImplementation();
    mock.apiFetch.mockImplementation(async (path: string, options: unknown) => {
      if (path === "/api/billing/credit-packs") return { data: [] };
      return original?.(path, options);
    });
    renderWithQueries(<AccountBillingPage />);
    expect(await screen.findByText("No credit packs are available right now.")).toBeInTheDocument();
    expect(screen.getByText("AI request")).toBeInTheDocument();
    expect(screen.getByRole("checkbox")).toBeDisabled();
  });

  it("lets the user turn off auto-recharge when the pack catalog fails", async () => {
    mock.pathname = "/account/spending";
    const original = mock.apiFetch.getMockImplementation();
    mock.apiFetch.mockImplementation(async (path: string, options: unknown) => {
      if (path === "/api/billing/overview")
        return {
          data: {
            ...overview,
            credits: {
              ...overview.credits,
              auto_recharge_enabled: true,
              auto_recharge_pack_key: "small",
              auto_recharge_threshold: 100,
            },
          },
        };
      if (path === "/api/billing/credit-packs") throw new Error("Catalog unavailable");
      if (path === "/api/billing/auto-recharge") return { data: {} };
      return original?.(path, options);
    });
    renderWithQueries(<AccountBillingPage />);
    await screen.findByText(/Credit packs could not be loaded/);
    const recharge = screen.getByRole("checkbox");
    expect(recharge).toBeChecked();
    expect(recharge).toBeEnabled();
    fireEvent.click(recharge);
    await waitFor(() =>
      expect(mock.apiFetch).toHaveBeenCalledWith("/api/billing/auto-recharge", {
        method: "POST",
        body: { enabled: false },
      }),
    );
  });

  it("disables all plan choices until the current checkout request finishes", async () => {
    mock.pathname = "/account/plans";
    const original = mock.apiFetch.getMockImplementation();
    mock.apiFetch.mockImplementation(async (path: string, options: unknown) => {
      if (path === "/api/billing/checkout") return new Promise(() => undefined);
      if (path === "/api/billing/plans")
        return {
          data: [
            { ...overview.subscription.plan, key: "team", name: "Team" },
            { ...overview.subscription.plan, key: "professional", name: "Professional" },
          ],
        };
      return original?.(path, options);
    });
    renderWithQueries(<AccountBillingPage />);
    const choices = await screen.findAllByRole("button", { name: "Choose" });
    fireEvent.click(choices[0]);
    await waitFor(() => choices.forEach((choice) => expect(choice).toBeDisabled()));
    expect(screen.getByRole("button", { name: "Monthly" })).toBeDisabled();
  });

  it("reports a checkout response that provides no redirect or activation", async () => {
    mock.pathname = "/account/plans";
    const original = mock.apiFetch.getMockImplementation();
    mock.apiFetch.mockImplementation(async (path: string, options: unknown) => {
      if (path === "/api/billing/checkout") return { data: {} };
      return original?.(path, options);
    });
    renderWithQueries(<AccountBillingPage />);
    fireEvent.click(await screen.findByRole("button", { name: "Choose" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("Checkout could not be started");
  });

  it("reports a payment portal response with no destination", async () => {
    mock.pathname = "/account/billing";
    const original = mock.apiFetch.getMockImplementation();
    mock.apiFetch.mockImplementation(async (path: string, options: unknown) => {
      if (path === "/api/billing/portal") return { data: {} };
      return original?.(path, options);
    });
    renderWithQueries(<AccountBillingPage />);
    fireEvent.click(await screen.findByRole("button", { name: "Manage billing" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("The payment portal did not open");
  });

  it("escapes invoice descriptions and disables all active content in printable copies", () => {
    const document = invoiceDocument(
      {
        id: "invoice",
        number: "<script>bad</script>",
        amount_cents: 1234,
        currency: "usd",
        status: "paid",
        issued_at: null,
        paid_at: null,
        line_items: [{ description: '<img src=x onerror="alert(1)">', amount_cents: 1234 }],
      },
      "<b>Company</b>",
    );
    expect(document).not.toContain("<script>");
    expect(document).not.toContain("<img");
    expect(document).toContain("&lt;img");
    expect(document).toContain("default-src 'none'");
  });
});

describe("Google sign-in continuation", () => {
  it("stores only the validated desktop request, not login path or arbitrary credentials", async () => {
    const path = "/desktop/authorize?request_id=11111111-2222-4333-8444-555555555555";
    window.history.replaceState(
      {},
      "",
      `/login?returnTo=${encodeURIComponent(`${path}&token=private`)}`,
    );
    mock.apiFetch.mockRejectedValue(new Error("provider unavailable"));
    render(<GoogleSignInButton />);
    fireEvent.click(screen.getByRole("button", { name: "Sign in with Google" }));
    await waitFor(() => expect(sessionStorage.getItem("google_auth_return")).toBe(path));
  });
});

describe("authenticated form continuations", () => {
  it("returns password sign-in to the requested account page after clearing old query data", async () => {
    window.history.replaceState({}, "", "/login?returnTo=%2Faccount%2Finvoices");
    const original = mock.apiFetch.getMockImplementation();
    mock.apiFetch.mockImplementation(async (path: string, options: unknown) => {
      if (path === "/api/auth/login") return { token: "new-session", user };
      return original?.(path, options);
    });
    renderWithQueries(<LoginPage />);
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: user.email } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "valid-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Sign in" }));
    await waitFor(() =>
      expect(mock.navigate).toHaveBeenCalledWith({ to: "/account/invoices", search: {} }),
    );
    expect(useAuthStore.getState().token).toBe("new-session");
    expect(screen.getByRole("link", { name: "Create your workspace" })).toBeInTheDocument();
  });

  it("returns registration to the validated desktop consent transaction", async () => {
    const id = "11111111-2222-4333-8444-555555555555";
    window.history.replaceState(
      {},
      "",
      `/signup?returnTo=${encodeURIComponent(`/desktop/authorize?request_id=${id}`)}`,
    );
    mock.apiFetch.mockResolvedValue({
      token: "registered-session",
      user,
      workspace: workspaces[0],
    });
    renderWithQueries(<SignupPage />);
    fireEvent.change(screen.getByLabelText("Your name"), { target: { value: "Ada Lovelace" } });
    fireEvent.change(screen.getByLabelText("Work email"), { target: { value: user.email } });
    fireEvent.change(screen.getByLabelText("Password"), { target: { value: "valid-password" } });
    fireEvent.click(screen.getByRole("button", { name: "Create account" }));
    await waitFor(() =>
      expect(mock.navigate).toHaveBeenCalledWith({
        to: "/desktop/authorize",
        search: { request_id: id },
      }),
    );
  });

  it("consumes Google continuation after establishing the actual returned session", async () => {
    window.history.replaceState({}, "", "/auth/google/callback?code=test-code&state=test-state");
    sessionStorage.setItem("google_auth_return", "/account/billing?checkout=success&token=private");
    mock.apiFetch.mockResolvedValue({
      token: "google-session",
      user,
      workspaces,
      status: "existing",
    });
    renderWithQueries(<GoogleAuthCallbackPage />);
    await waitFor(() =>
      expect(mock.navigate).toHaveBeenCalledWith({
        to: "/account/billing",
        search: { checkout: "success" },
      }),
    );
    expect(sessionStorage.getItem("google_auth_return")).toBeNull();
    expect(useAuthStore.getState().token).toBe("google-session");
  });
});
