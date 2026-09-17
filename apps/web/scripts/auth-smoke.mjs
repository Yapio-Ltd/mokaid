/** Local-only, real Chrome flow: no external provider or production accounts. */
import assert from "node:assert/strict";
import { randomBytes, createHash } from "node:crypto";
import { createServer } from "node:http";
import { chromium } from "playwright";

const web = process.env.AUTH_SMOKE_WEB || "http://127.0.0.1:5177";
const api = process.env.AUTH_SMOKE_API || "http://127.0.0.1:4017";
for (const base of [web, api])
  assert.equal(new URL(base).hostname, "127.0.0.1", "Smoke tests require isolated local servers");
const email = `browser-smoke-${Date.now()}@example.test`;
const password = randomBytes(24).toString("base64url");
const verifier = randomBytes(32).toString("base64url");
const state = randomBytes(32).toString("base64url");
let callbackResolve;
const receivedCallback = new Promise((resolve) => {
  callbackResolve = resolve;
});
const listener = createServer((request, response) => {
  const url = new URL(request.url, "http://127.0.0.1");
  if (url.pathname !== "/callback") {
    response.writeHead(404).end();
    return;
  }
  callbackResolve({ code: url.searchParams.get("code"), state: url.searchParams.get("state") });
  response.writeHead(200, { "Content-Type": "text/plain", "Cache-Control": "no-store" });
  response.end("Desktop sign-in complete.");
});
await new Promise((resolve) => listener.listen(0, "127.0.0.1", resolve));
const redirect = `http://127.0.0.1:${listener.address().port}/callback`;
const browser = await chromium.launch({ channel: "chrome", headless: true });
const context = await browser.newContext();
const page = await context.newPage();
const errors = [];
page.on("pageerror", (error) => errors.push(error.message));
async function apiPost(path, body) {
  const response = await fetch(`${api}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  assert(response.ok, `${path}: ${response.status}`);
  return response.status === 204 ? null : response.json();
}
try {
  await page.goto(`${web}/signup?returnTo=%2Faccount`);
  await page.getByLabel("Your name").fill("Smoke Test User");
  await page.getByLabel("Work email").fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: /Create (workspace|account)/ }).click();
  await page.waitForURL(`${web}/account`, { timeout: 30_000 });
  await page.getByRole("button", { name: "Sign out" }).waitFor();
  const marker = await page.evaluate(
    () => JSON.parse(localStorage.getItem("mokaid-auth")).state.token,
  );
  assert(marker.startsWith("browser:"));
  assert(!marker.includes("mw_st_"));
  assert(!(await page.evaluate(() => document.cookie)).includes("_mokaid_key"));
  const cookie = (await context.cookies()).find((item) => item.name === "_mokaid_key");
  assert(cookie?.httpOnly && cookie.sameSite === "Lax");
  const csrfCheck = await page.evaluate(
    async () =>
      (
        await fetch("/api/me", {
          method: "PATCH",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ full_name: "CSRF should fail" }),
        })
      ).status,
  );
  assert.equal(csrfCheck, 403);
  const socket = await page.evaluate(async (marker) => {
    const url = new URL("/socket/websocket", location.href);
    url.protocol = "ws:";
    url.searchParams.set("vsn", "2.0.0");
    url.searchParams.set("_csrf_token", marker.slice("browser:".length));
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      const timeout = setTimeout(() => {
        socket.close();
        reject(new Error("WebSocket auth timeout"));
      }, 8000);
      socket.onopen = () => socket.send(JSON.stringify([null, "1", "phoenix", "heartbeat", {}]));
      socket.onerror = () => {
        clearTimeout(timeout);
        reject(new Error("WebSocket authentication failed"));
      };
      socket.onmessage = (message) => {
        clearTimeout(timeout);
        const payload = JSON.parse(message.data);
        socket.close();
        resolve(payload[4]?.status);
      };
    });
  }, marker);
  assert.equal(socket, "ok");
  const request = await apiPost("/api/desktop/auth/requests", {
    code_challenge: createHash("sha256").update(verifier).digest("base64url"),
    code_challenge_method: "S256",
    state,
    redirect_uri: redirect,
  });
  await page.goto(request.data.authorization_url);
  await page.getByRole("button", { name: "Connect this computer" }).click();
  const callback = await Promise.race([
    receivedCallback,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error("Loopback callback timeout")), 15_000),
    ),
  ]);
  assert.equal(callback.state, state);
  assert(callback.code);
  const exchanged = await apiPost("/api/desktop/auth/token", {
    grant_type: "authorization_code",
    code: callback.code,
    code_verifier: verifier,
    redirect_uri: redirect,
  });
  const refreshed = await apiPost("/api/desktop/auth/token", {
    grant_type: "refresh_token",
    refresh_token: exchanged.data.refresh_token,
  });
  assert.notEqual(refreshed.data.refresh_token, exchanged.data.refresh_token);
  const peer = await context.newPage();
  await peer.goto(`${web}/account`);
  await peer.getByRole("button", { name: "Sign out" }).waitFor();
  await page.goto(`${web}/account`);
  await page.getByRole("button", { name: "Sign out" }).click();
  await page.waitForURL(/\/login/, { timeout: 10_000 });
  await peer.waitForURL(/\/login/, { timeout: 10_000 });
  await peer.close();
  const revokedBrowser = await fetch(`${api}/api/me`, {
    headers: { Cookie: `${cookie.name}=${cookie.value}` },
  });
  assert.equal(revokedBrowser.status, 401);
  const nativeMe = await fetch(`${api}/api/me`, {
    headers: { Authorization: `Bearer ${refreshed.data.access_token}` },
  });
  assert.equal(nativeMe.status, 200);
  await apiPost("/api/desktop/auth/revoke", { refresh_token: refreshed.data.refresh_token });
  const revokedNative = await fetch(`${api}/api/me`, {
    headers: { Authorization: `Bearer ${refreshed.data.access_token}` },
  });
  assert.equal(revokedNative.status, 401);
  await page.goto(`${web}/login?returnTo=%2Faccount`);
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL(`${web}/account`, { timeout: 15_000 });
  await page.getByRole("button", { name: "Sign out" }).click();
  await page.waitForURL(/\/login/, { timeout: 10_000 });
  assert.deepEqual(errors, []);
  console.log(
    JSON.stringify(
      {
        result: "PASS",
        checks: [
          "signup form",
          "HttpOnly cookie",
          "no bearer in localStorage",
          "CSRF rejected",
          "real authenticated WebSocket heartbeat",
          "browser consent",
          "real loopback callback",
          "PKCE exchange",
          "refresh rotation",
          "browser logout revocation",
          "native session independence",
          "native revocation",
          "cross-tab logout",
          "password login form",
        ],
        pageErrors: errors.length,
      },
      null,
      2,
    ),
  );
} catch (failure) {
  console.error(
    JSON.stringify(
      {
        url: new URL(page.url()).pathname,
        body: (await page.locator("body").innerText()).slice(-2500),
        pageErrors: errors,
      },
      null,
      2,
    ),
  );
  await page.screenshot({ path: "/tmp/mokaid-auth-smoke-failure.png", fullPage: true });
  throw failure;
} finally {
  await browser.close();
  listener.close();
}
