import assert from "node:assert/strict";

const origin = process.env.MOKAID_SMOKE_ORIGIN ?? "https://mokaid.com";
const target = new URL(origin);
assert.ok(target.origin === origin && (target.protocol === "https:" || target.hostname === "127.0.0.1"), "Explicit HTTPS or local smoke origin required");
async function read(path, expected = 200) {
  const response = await fetch(`${origin}${path}`, { redirect: "manual", signal: AbortSignal.timeout(15_000) });
  assert.equal(response.status, expected, `Unexpected status at ${path}`);
  return response;
}
for (const path of ["/", "/pricing", "/download"]) {
  const response = await read(path);
  const html = await response.text();
  assert.match(html, /name="mokaid-web-surface" content="marketing-account"/, `Wrong web surface at ${path}`);
  if (path === "/") {
    assert.match(html, /href="\/download"/, "Landing must expose desktop downloads");
    assert.match(html, /href="\/login"/, "Landing must expose account sign-in");
    assert.doesNotMatch(html, /href="\/dashboard"/, "Landing must not launch the Office");
  }
  assert.match(html, /<h1(?:\s|>)/i, `Missing prerendered content at ${path}`);
  assert.ok(html.includes(`href="https://mokaid.com${path}"`), `Missing canonical at ${path}`);
  assert.doesNotMatch(response.headers.get("x-robots-tag") ?? "", /noindex/i);
}
const sitemap = await (await read("/sitemap.xml")).text();
assert.match(sitemap, /<urlset/);
assert.match(sitemap, /https:\/\/mokaid.com\/download/);
assert.doesNotMatch(sitemap, /<loc>[^<]*\/(account|dashboard|login|desktop\/authorize)/);
for (const path of ["/account", "/login", "/desktop/authorize"]) {
  const response = await read(path);
  assert.match(response.headers.get("x-robots-tag") ?? "", /noindex/);
  assert.match(response.headers.get("cache-control") ?? "", /no-store/);
}
await read("/mokaid-unknown-route-smoke-test", 404);
// Local nginx smoke does not proxy API: ECS routes API separately at the ALB.
if (target.protocol === "https:") {
  await read("/api/health");
  await read("/api/me", 401);
  await read("/api/desktop/auth/requests/00000000-0000-4000-8000-000000000000", 401);
}
console.log(`Public HTML, sitemap, private-page headers and 404 checks passed${target.protocol === "https:" ? "; API smoke passed" : "; API excluded from this local nginx check"}.`);
