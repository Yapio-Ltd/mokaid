/** Compiled account-only build probe. All API traffic is intercepted with local
 * fixtures and all non-local traffic is blocked. Never points at production.
 * Build normally, preview on 127.0.0.1:5189, then:
 * node tests/browser/account-portal.mjs [http://127.0.0.1:5189] [artifact-dir]
 */
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { chromium } from "playwright";

const origin = new URL(process.argv[2] ?? "http://127.0.0.1:5189");
assert.equal(origin.hostname, "127.0.0.1", "Only an isolated loopback preview is allowed");
assert.equal(origin.protocol, "http:");
const artifacts = resolve(process.argv[3] ?? "/private/tmp/mokaid-account-browser-results");
await mkdir(artifacts, { recursive: true });

const user = {
  id: "browser-fixture",
  full_name: "Ada Example",
  email: "ada@example.invalid",
  avatar_url: null,
  has_password: true,
  auth_provider: "password",
  timezone: "UTC",
  locale: "en",
};
const workspaces = [
  { id: "one", name: "Example team", slug: "example", logo_url: null, role_name: "Owner" },
  { id: "two", name: "Second team", slug: "second", logo_url: null, role_name: "Owner" },
];
const plan = {
  key: "starter",
  name: "Starter",
  price_cents_monthly: 4900,
  price_cents_yearly: 49000,
  limits: { agents: 3, credits_monthly: 5000 },
  features: ["Desktop office", "AI agents"],
};
const overview = {
  subscription: {
    id: "subscription",
    status: "active",
    billing_cycle: "monthly",
    current_period_start: "2026-09-01",
    current_period_end: "2026-10-01",
    payment_method: { brand: "visa", last4: "4242" },
    credits_balance: 4100,
    plan,
  },
  credits: {
    included_remaining: 4000,
    balance: 100,
    spendable: 4100,
    monthly_credits: 5000,
    unlimited: false,
    auto_recharge_enabled: false,
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
const invoice = {
  id: "invoice",
  number: "INV-EXAMPLE-001",
  status: "paid",
  amount_cents: 4900,
  currency: "usd",
  issued_at: "2026-09-01",
  paid_at: "2026-09-01",
  line_items: [{ description: "Starter subscription", amount_cents: 4900 }],
};
const requestId = "11111111-2222-4333-8444-555555555555";
const forbiddenResource =
  /\.(?:glb|gltf|wasm)(?:\?|$)|\/assets\/(?:app-shell|dashboard|office-scene|agent-preview|babylon|recast)|\/socket(?:\/|\?)/i;

class AccountPortal {
  constructor(page) {
    this.page = page;
  }
  async open(path = "/account") {
    await this.page.goto(new URL(path, origin).href);
  }
  async section(label, title) {
    await this.page
      .getByRole("navigation", { name: "Account", exact: true })
      .getByRole("link", { name: label, exact: true })
      .click();
    await this.page.getByRole("heading", { name: title, exact: true, level: 1 }).waitFor();
  }
  async login() {
    await this.page.getByLabel("Email", { exact: true }).fill(user.email);
    await this.page.getByLabel("Password", { exact: true }).fill("test-fixture-password");
    await this.page.getByRole("button", { name: "Sign in", exact: true }).click();
  }
}

const browser = await chromium.launch({ headless: true });
const results = [];
async function probe(name, signedIn, run, viewport = { width: 1440, height: 1000 }) {
  const context = await browser.newContext({ viewport, reducedMotion: "reduce" });
  const calls = [];
  const resources = [];
  const faults = [];
  await context.tracing.start({ screenshots: true, snapshots: true });
  await context.addInitScript(
    ({ signedIn, user, workspaces }) => {
      if (signedIn)
        localStorage.setItem(
          "mokaid-auth",
          JSON.stringify({
            state: { token: "browser:fixture-csrf", user, workspaces, workspaceId: "one" },
            version: 1,
          }),
        );
    },
    { signedIn, user, workspaces },
  );
  await context.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    resources.push(url.href);
    if (url.pathname.startsWith("/api/")) {
      const request = route.request();
      calls.push({
        path: url.pathname,
        method: request.method(),
        body: request.postDataJSON(),
        workspace: request.headers()["x-workspace-id"],
        csrf: request.headers()["x-csrf-token"],
        authorization: request.headers()["authorization"],
      });
      let json;
      if (url.pathname === "/api/me")
        json = { user, workspaces, client_policy: { desktop_only_business: false } };
      else if (url.pathname === "/api/auth/login") json = { token: "browser:fixture-login-csrf", user };
      else if (url.pathname === "/api/auth/logout") json = { ok: true };
      else if (url.pathname === "/api/billing/overview") json = { data: overview };
      else if (url.pathname === "/api/billing/plans")
        json = { data: [plan, { ...plan, key: "team", name: "Team", price_cents_monthly: 8900 }] };
      else if (url.pathname === "/api/billing/invoices") json = { data: [invoice] };
      else if (url.pathname === "/api/billing/credit-packs")
        json = { data: [{ key: "small", credits: 1000, price_cents: 1000 }] };
      else if (url.pathname === "/api/billing/checkout") json = { data: { activated: true } };
      else if (url.pathname === `/api/desktop/auth/requests/${requestId}`)
        json = {
          data: {
            request_id: requestId,
            application: "Mokaid Desktop",
            redirect_uri: "http://127.0.0.1:49190/callback",
            expires_at: "2099-01-01T00:00:00Z",
            user,
          },
        };
      else {
        faults.push(`Unexpected API request: ${request.method()} ${url.pathname}`);
        return route.fulfill({
          status: 403,
          json: { error: { code: "probe_denied", message: "Not an account endpoint" } },
        });
      }
      return route.fulfill({ status: 200, json });
    }
    if (url.origin !== origin.origin) return route.abort("blockedbyclient");
    if (forbiddenResource.test(url.href)) {
      faults.push(`Business resource loaded: ${url.pathname}`);
      return route.abort("blockedbyclient");
    }
    return route.continue();
  });
  const page = await context.newPage();
  page.on("pageerror", (error) => faults.push(error.message));
  page.on("websocket", (socket) => faults.push(`Unexpected websocket: ${socket.url()}`));
  const portal = new AccountPortal(page);
  try {
    await run({ page, portal, calls });
    assert.deepEqual(faults, []);
    assert.equal(
      resources.some((url) => forbiddenResource.test(url)),
      false,
    );
    assert.equal(await page.locator("canvas").count(), 0, "No renderer canvas in account portal");
    results.push({ name, status: "pass", apiRequests: calls.length, businessResources: 0 });
  } catch (error) {
    await page.screenshot({ path: resolve(artifacts, `${name}-failure.png`), fullPage: true });
    results.push({ name, status: "fail", error: String(error), faults });
    throw error;
  } finally {
    await context.tracing.stop({ path: resolve(artifacts, `${name}-trace.zip`) });
    await context.close();
  }
}

try {
  await Promise.all([
    ...[false, true].flatMap((signedIn) =>
      [{ width: 1440, height: 1000 }, { width: 390, height: 844 }].map((viewport) =>
        probe(`landing-${signedIn ? "signed-in" : "public"}-${viewport.width}`, signedIn, async ({ page, portal }) => {
          await portal.open("/");
          await page.getByRole("heading", { name: "mokaid", exact: true, level: 1 }).waitFor();
          assert.equal(new URL(page.url()).pathname, "/");
          const header = page.locator("header").first();
          await header.getByRole("link", { name: "Download", exact: true }).waitFor();
          await header.getByRole("link", { name: signedIn ? "My account" : "Sign in", exact: true }).waitFor();
          assert.equal(await page.locator('a[href="/dashboard"]').count(), 0);
          assert.equal(await page.locator('[data-hero-scene]').evaluate((el) => getComputedStyle(el).opacity), "1");
          assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
          const consent = page.getByRole("button", { name: "Essential only" });
          if (await consent.isVisible()) await consent.click();
          await page.screenshot({ path: resolve(artifacts, `landing-${signedIn ? "signed-in" : "public"}-${viewport.width}.png`) });
          if (!signedIn) {
            await page.locator(".mk-final-cta").scrollIntoViewIfNeeded();
            await page.locator(".mk-final-cta").screenshot({ path: resolve(artifacts, `landing-final-${viewport.width}.png`), animations: "disabled" });
            await page.evaluate(() => window.scrollTo(0, 0));
          }
          await header.getByRole("link", { name: "Download", exact: true }).click();
          await page.waitForURL((url) => url.pathname === "/download");
          for (const path of ["/dashboard", "/agents/new", "/projects", "/tasks", "/integrations"]) {
            await portal.open(path);
            await page.waitForURL((url) => url.pathname === "/download");
          }
        }, viewport),
      ),
    ),
    probe("portal", true, async ({ page, portal, calls }) => {
      await portal.open();
      await page.getByRole("heading", { name: "Your account", exact: true }).waitFor();
      const cookieChoice = page.getByRole("button", { name: "Essential only" });
      if (await cookieChoice.isVisible()) await cookieChoice.click();
      assert.match(await page.locator('meta[name="robots"]').getAttribute("content"), /noindex/);
      await page.screenshot({ path: resolve(artifacts, "account-overview.png"), fullPage: true });
      await portal.section("Profile & preferences", "Profile");
      await page.getByLabel("Full name", { exact: false }).waitFor();
      await portal.section("Security", "Security");
      await page.getByLabel("Current password", { exact: false }).waitFor();
      await portal.section("Billing", "Billing");
      await page.getByRole("button", { name: "Manage billing", exact: true }).waitFor();
      await page.screenshot({ path: resolve(artifacts, "account-billing.png"), fullPage: true });
      await portal.section("Plans", "Plans");
      await page.getByRole("button", { name: "Choose", exact: true }).click();
      await page.getByRole("status").filter({ hasText: "Your plan has been updated." }).waitFor();
      assert.equal(
        calls.find((call) => call.path === "/api/billing/checkout")?.body.return_path,
        "/account/billing",
      );
      assert.equal(calls.find((call) => call.path === "/api/billing/checkout")?.csrf, "fixture-csrf");
      assert.equal(calls.some((call) => call.authorization), false);
      await portal.section("Usage", "Usage");
      await page.getByText("Usage this billing period", { exact: true }).waitFor();
      await portal.section("Spending & credits", "Spending & credits");
      await page.getByText("Recent credit transactions", { exact: true }).waitFor();
      await portal.section("Invoices", "Invoices");
      const downloadEvent = page.waitForEvent("download");
      await page.getByRole("button", { name: "Download printable copy" }).click();
      const download = await downloadEvent;
      assert.equal(download.suggestedFilename(), "Mokaid-invoice-INV-EXAMPLE-001.html");
      await download.saveAs(resolve(artifacts, download.suggestedFilename()));
      const switchedOverview = page.waitForResponse(
        (response) =>
          response.url().endsWith("/api/billing/overview") &&
          response.request().headers()["x-workspace-id"] === "two",
      );
      await page.getByLabel("Billing workspace").selectOption("two");
      await switchedOverview;
      await page.getByRole("button", { name: "Sign out", exact: true }).click();
      await page.waitForURL((url) => url.pathname === "/login");
      assert.equal(calls.find((call) => call.path === "/api/auth/logout")?.method, "POST");
    }),
    probe("login-direct-link", false, async ({ page, portal, calls }) => {
      await portal.open("/account/invoices");
      await page.getByRole("heading", { name: "Welcome back" }).waitFor();
      assert.equal(new URL(page.url()).searchParams.get("returnTo"), "/account/invoices");
      await portal.login();
      await page.getByRole("heading", { name: "Invoices", exact: true, level: 1 }).waitFor();
      assert.equal(calls.find((call) => call.path === "/api/auth/login")?.body.session_transport, "cookie");
      assert.equal(calls.find((call) => call.path === "/api/me")?.csrf, "fixture-login-csrf");
      assert.equal(new URL(page.url()).pathname, "/account/invoices");
      await portal.open("/billing?checkout=success&token=private");
      await page.getByRole("heading", { name: "Billing", exact: true, level: 1 }).waitFor();
      await page.getByRole("status").filter({ hasText: "Payment returned successfully" }).waitFor();
      assert.equal(new URL(page.url()).searchParams.has("token"), false);
    }),
    probe("desktop-consent", false, async ({ page, portal }) => {
      await portal.open(`/desktop/authorize?request_id=${requestId}`);
      await page.getByRole("link", { name: "Sign in to Mokaid" }).click();
      await portal.login();
      await page.getByRole("button", { name: "Connect this computer", exact: true }).waitFor();
      assert.equal(new URL(page.url()).searchParams.get("request_id"), requestId);
      // Deliberately do not approve or navigate to the loopback callback.
    }),
    probe(
      "mobile-account",
      true,
      async ({ page, portal }) => {
        await portal.open("/account");
        await page.getByRole("heading", { name: "Your account", exact: true }).waitFor();
        assert.equal(
          await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
          true,
        );
        await page.screenshot({ path: resolve(artifacts, "account-mobile.png"), fullPage: true });
      },
      { width: 390, height: 844 },
    ),
  ]);
} finally {
  await writeFile(resolve(artifacts, "results.json"), JSON.stringify(results, null, 2));
  await browser.close();
}
console.log(JSON.stringify(results, null, 2));
