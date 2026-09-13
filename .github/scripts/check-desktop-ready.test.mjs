import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { checkDesktopReady, DOWNLOADS } from "./check-desktop-ready.mjs";
const fixture = () => ({ schemaVersion: 1, channel: "stable", version: "1.2.3", publishedAt: "2026-09-01T00:00:00Z", releaseNotesUrl: "https://github.com/Yapio-Ltd/mokaid/releases/tag/desktop-v1.2.3", downloads: Object.fromEntries([["macos-arm64", "dmg"], ["windows-x64", "exe"]].map(([platform, ext]) => [platform, { url: `${DOWNLOADS}/releases/1.2.3/Mokaid-1.2.3-${platform}.${ext}`, size: 12, sha256: createHash("sha256").update("fixturebytes").digest("hex") }])) });
const remote = (release, status = 200, size = 12, body = "fixturebytes") => async (url) => url.endsWith("release.json") ? new Response(JSON.stringify(release)) : new Response(body, { status, headers: { "content-length": `${size}` } });
test("accepts only stable release with both real installer lengths", async () => assert.equal(await checkDesktopReady(remote(fixture())), "1.2.3"));
test("missing Windows, unsigned channel, external URL and changed binary block rollout", async () => {
  const missing = fixture(); delete missing.downloads["windows-x64"];
  const beta = { ...fixture(), channel: "beta" };
  const external = fixture(); external.downloads["macos-arm64"].url = "https://evil.invalid/setup.dmg";
  for (const release of [missing, beta, external]) await assert.rejects(checkDesktopReady(remote(release)));
  await assert.rejects(checkDesktopReady(remote(fixture(), 404)));
  await assert.rejects(checkDesktopReady(remote(fixture(), 200, 11)));
  await assert.rejects(checkDesktopReady(remote(fixture(), 200, 12, "corruptbytes")), /checksum mismatch/);
  await assert.rejects(checkDesktopReady(remote(fixture(), 200, 12, "short")), /truncated/);
});
