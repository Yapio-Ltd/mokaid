import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";

export const DOWNLOADS = "https://downloads.mokaid.com";
/** The stable manifest is published only by the protected, signed promotion.
 * Never substitute a GitHub draft, an unsigned build or a development DMG.
 */
export async function checkDesktopReady(fetcher = fetch) {
  const response = await fetcher(`${DOWNLOADS}/stable/release.json`, { redirect: "error", signal: AbortSignal.timeout(15_000) });
  assert.equal(response.status, 200, "No verified stable desktop release is available");
  const body = await response.text();
  assert.ok(body.length <= 32_768, "Oversized release manifest");
  const release = JSON.parse(body);
  assert.equal(release.schemaVersion, 1);
  assert.equal(release.channel, "stable");
  assert.match(release.version, /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/);
  assert.equal(release.releaseNotesUrl, `https://github.com/Yapio-Ltd/mokaid/releases/tag/desktop-v${release.version}`);
  assert.ok(Number.isFinite(Date.parse(release.publishedAt)));
  for (const [platform, extension] of [["macos-arm64", "dmg"], ["windows-x64", "exe"]]) {
    const artifact = release.downloads?.[platform];
    assert.equal(artifact?.url, `${DOWNLOADS}/releases/${release.version}/Mokaid-${release.version}-${platform}.${extension}`);
    assert.match(artifact.sha256, /^[0-9a-f]{64}$/);
    assert.ok(Number.isSafeInteger(artifact.size) && artifact.size > 0);
    assert.ok(artifact.size <= 4 * 1024 ** 3, "Installer exceeds distribution size budget");
    const installer = await fetcher(artifact.url, { redirect: "error", signal: AbortSignal.timeout(600_000) });
    assert.equal(installer.status, 200, `${platform} installer unavailable`);
    assert.equal(Number(installer.headers.get("content-length")), artifact.size, `${platform} installer length mismatch`);
    assert.ok(installer.body, "Empty installer stream");
    const hash = createHash("sha256");
    let bytes = 0;
    for await (const chunk of installer.body) {
      bytes += chunk.length;
      assert.ok(bytes <= artifact.size, `${platform} installer exceeds declared length`);
      hash.update(chunk);
    }
    assert.equal(bytes, artifact.size, `${platform} truncated installer`);
    assert.equal(hash.digest("hex"), artifact.sha256, `${platform} installer checksum mismatch`);
  }
  return release.version;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try { console.log(`Verified stable desktop ${await checkDesktopReady()}: both installers available.`); }
  catch (error) { console.error(`Desktop-only rollout blocked: ${error.message}`); process.exitCode = 1; }
}
