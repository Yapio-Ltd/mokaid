import test from "node:test";
import assert from "node:assert/strict";
import { assertSnapshot, buildSitemap, privateShell, publicRoute } from "./prerender-policy.mjs";

const html = `<!doctype html><html><head><title>Download Mokaid Desktop</title><meta name="description" content="Download Mokaid for macOS and Windows to work with your AI employees."><link rel="canonical" href="https://mokaid.com/download"><script type="application/ld+json" data-seo-jsonld>{"@type":"SoftwareApplication"}</script></head><body><div id="root"><h1>Download Mokaid Desktop</h1><p>Use the native desktop application to work with your AI employees. Manage your account, usage and invoices on the website.</p></div></body></html>`;
test("only canonical public routes are crawled", () => {
  assert.equal(publicRoute("/download/?ref=test#macos"), "/download");
  assert.equal(publicRoute("/blog/ai-teams"), "/blog/ai-teams");
  for (const path of ["//evil.invalid", "/blog/../account", "/blog/%2e%2e", "/pricing/customer", "/account", "/api/me", "/desktop/authorize?code=test", "/blog/a\\b"]) assert.equal(publicRoute(path), null);
});
test("sitemap excludes private and legal paths and invented freshness", () => {
  const xml = buildSitemap(["/", "/download", "/download", "/privacy", "/account"]);
  assert.equal((xml.match(/<url>/g) ?? []).length, 2);
  assert.match(xml, /https:\/\/mokaid.com\/download/);
  assert.doesNotMatch(xml, /lastmod|priority|account|privacy/);
});
test("accepts actual indexable snapshot", () => assert.doesNotThrow(() => assertSnapshot("/download", html)));
test("rejects empty, miscanonicalized, noindex and broken JSON snapshots", () => {
  for (const bad of [html.replace("https://mokaid.com/download", "https://mokaid.com/"), html.replace("<h1>", "<div>").replace("</h1>", "</div>"), html.replace("</head>", '<meta name="robots" content="noindex"></head>'), html.replace('{"@type":"SoftwareApplication"}', "{broken")]) assert.throws(() => assertSnapshot("/download", bad));
});
test("private SPA shell never inherits canonical or public structured data", () => {
  const shell = privateShell(html.replace(/<div id="root">.*<\/div>/, '<div id="root"></div>'));
  assert.match(shell, /noindex, nofollow/);
  assert.match(shell, /Mokaid Account/);
  assert.doesNotMatch(shell, /canonical|data-seo-jsonld/);
});
