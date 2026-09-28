/** Validate Nginx headers for fingerprinted cinematic WebP frames. */
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
const sample = (story.frames.desktop.base || story.frames.desktop).pattern.replace(
  "%05d",
  "00001",
);
const bytes = (await stat(`${dist}${sample}`)).size;
const image = process.argv[2] || "nginx:1.30.4-alpine";
const name = `mokaid-cinema-header-qa-${process.pid}`;
const port = 5191;
const origin = `http://127.0.0.1:${port}`;
const output = `${root}artifacts/mokaid-cinema-2026-09-28/verification`;
const report = { image, config, media: sample, bytes, requests: [], deployment: false };
const docker = (args) => {
  const result = spawnSync("docker", args, { encoding: "utf8", timeout: 30000 });
  assert.equal(result.status, 0, result.stderr || result.error?.message || "docker failed");
  return result.stdout.trim();
};
let started = false;
try {
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
  const head = await probe(sample, { method: "HEAD" });
  assert.equal(head.status, 200);
  assert.match(head.headers["content-type"] || "", /image\/webp/);
  assert.equal(head.headers["content-length"], String(bytes));
  assert.equal(head.headers["cache-control"], "public, max-age=31536000, immutable");
  const get = await probe(sample, { method: "GET" });
  assert.equal(get.status, 200);
  assert.equal(get.responseBytes, bytes);
  const missing = await probe("/assets/cinematic-deliberately-missing.webp", { method: "HEAD" });
  assert.equal(missing.status, 404);
  assert.equal(missing.headers["cache-control"], "no-store");
  report.status = "passed";
} catch (error) {
  report.status = "failed";
  report.error = { message: error.message, stack: error.stack };
  process.exitCode = 1;
} finally {
  if (started) spawnSync("docker", ["rm", "-f", name], { encoding: "utf8" });
  await mkdir(output, { recursive: true });
  await writeFile(`${output}/production-asset-headers.json`, `${JSON.stringify(report, null, 2)}\n`);
}
console.log(JSON.stringify({ status: report.status, media: sample, bytes }, null, 2));
