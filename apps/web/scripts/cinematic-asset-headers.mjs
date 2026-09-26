/** Validate the repository's production Nginx config locally using an existing image. */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFile, mkdir, writeFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../../../", import.meta.url));
const dist = `${root}apps/web/dist`;
const config = `${root}infra/docker/nginx.conf`;
const story = JSON.parse(
  await readFile(new URL("../src/data/cinematic-story.json", import.meta.url), "utf8"),
);
const bytes = (await stat(`${dist}${story.video}`)).size;
const image = process.argv[2] || "nginx:1.30.4-alpine";
const name = `mokaid-cinema-header-qa-${process.pid}`;
const port = 5191;
const origin = `http://127.0.0.1:${port}`;
const output = `${root}artifacts/mokaid-cinema-2026-09-25/verification`;
const report = { image, config, media: story.video, bytes, requests: [], deployment: false };
const docker = (args) => {
  const result = spawnSync("docker", args, { encoding: "utf8", timeout: 30000 });
  assert.equal(result.status, 0, result.stderr || result.error?.message || "docker failed");
  return result.stdout.trim();
};
let started = false;
try {
  // inspect refuses a missing local image; no pull/build is performed by this test.
  docker(["image", "inspect", image]);
  docker([
    "run",
    "--pull=never",
    "--rm",
    "-d",
    "--name",
    name,
    "--read-only",
    "--tmpfs",
    "/var/cache/nginx",
    "--tmpfs",
    "/var/run",
    "-p",
    `127.0.0.1:${port}:80`,
    "-v",
    `${dist}:/usr/share/nginx/html:ro`,
    "-v",
    `${config}:/etc/nginx/conf.d/default.conf:ro`,
    image,
  ]);
  started = true;
  let ready = false;
  for (let i = 0; i < 20; i++) {
    try {
      const response = await fetch(`${origin}/healthz`);
      if (response.ok) {
        ready = true;
        break;
      }
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.ok(ready, "Temporary Nginx health check");
  const probe = async (path, options) => {
    const response = await fetch(`${origin}${path}`, options);
    const body = Buffer.from(await response.arrayBuffer());
    const result = {
      path,
      request: options,
      status: response.status,
      headers: Object.fromEntries(response.headers),
      responseBytes: body.length,
    };
    report.requests.push(result);
    return result;
  };
  const head = await probe(story.video, { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.equal(head.headers["content-type"], "video/mp4");
  assert.equal(head.headers["content-length"], String(bytes));
  assert.equal(head.headers["accept-ranges"], "bytes");
  assert.equal(head.headers["cache-control"], "public, max-age=31536000, immutable");
  assert.ok(head.headers.etag);
  assert.equal(head.headers["content-encoding"], undefined);
  const unchanged = await probe(story.video, {
    method: "HEAD",
    headers: { "If-None-Match": head.headers.etag },
  });
  assert.equal(unchanged.status, 304);
  assert.equal(unchanged.headers["cache-control"], head.headers["cache-control"]);
  const first = await probe(story.video, { headers: { Range: "bytes=0-1023" } });
  assert.equal(first.status, 206);
  assert.equal(first.headers["content-range"], `bytes 0-1023/${bytes}`);
  assert.equal(first.responseBytes, 1024);
  assert.equal(first.headers["cache-control"], head.headers["cache-control"]);
  const suffix = await probe(story.video, { headers: { Range: "bytes=-1024" } });
  assert.equal(suffix.status, 206);
  assert.equal(suffix.headers["content-range"], `bytes ${bytes - 1024}-${bytes - 1}/${bytes}`);
  assert.equal(suffix.responseBytes, 1024);
  const invalid = await probe(story.video, { headers: { Range: `bytes=${bytes + 1}-` } });
  assert.equal(invalid.status, 416);
  assert.equal(invalid.headers["content-range"], `bytes */${bytes}`);
  // Nginx's late Range error can retain the first header pass; no-store forbids
  // storage even when the earlier successful-response directives remain present.
  assert.ok(invalid.headers["cache-control"].split(/,\s*/).includes("no-store"));
  const missing = await probe("/assets/cinematic-deliberately-missing.mp4", { method: "HEAD" });
  assert.equal(missing.status, 404);
  assert.equal(missing.headers["cache-control"], "no-store");
  const html = await probe("/", { method: "HEAD" });
  assert.equal(html.status, 200);
  assert.equal(html.headers["cache-control"], "no-cache, must-revalidate");
  report.status = "passed";
  report.configChangeNeeded = false;
  report.configChangeApplied =
    "Final response cache map sets no-store on 4xx/5xx; 2xx/3xx retain the existing URI-based policy.";
  report.lateRangeErrorNote =
    "This Nginx build retains successful-response cache directives from the first header pass on 416; the volatile status map adds no-store on the final pass, which forbids storage. The ordinary404 returns only no-store.";
  report.productionCaveat =
    "This verifies the repository config and local compiled files in Nginx, not the deployed CDN/origin. Deployment must preserve206, Content-Range, Accept-Ranges and fingerprinted asset cache headers.";
} catch (error) {
  report.status = "failed";
  report.error = { message: error.message, stack: error.stack };
  process.exitCode = 1;
} finally {
  if (started) docker(["stop", "-t", "1", name]);
  await mkdir(output, { recursive: true });
  await writeFile(
    `${output}/production-asset-headers.json`,
    JSON.stringify(report, null, 2) + "\n",
  );
}
console.log(JSON.stringify(report, null, 2));
