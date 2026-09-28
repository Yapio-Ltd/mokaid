#!/usr/bin/env node
/**
 * Export cinematic WebP packs:
 * - desktop/base: 720x405 @ 3fps (TTI bootstrap)
 * - desktop-high: 1280x720 @ 12fps (desktop densify)
 * - mobile: 480x270 @ 2fps (unchanged; never densified)
 */
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

const here = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(here, "..");
const repoRoot = resolve(webRoot, "../..");
const storyPath = join(webRoot, "src/data/cinematic-story.json");
const story = JSON.parse(readFileSync(storyPath, "utf8"));
const sourceMp4 =
  process.env.MOKAID_CINEMA_SOURCE ||
  join(
    repoRoot,
    "artifacts/mokaid-cinema-2026-09-25/deliveries/mokaid-office-journey.adac1c365481.mp4",
  );

/** Frozen mobile + desktop-base specs (must not drift). */
const MOBILE_LOCK = {
  width: 480,
  height: 270,
  fps: 2,
  count: 148,
  quality: 50,
  maxBytes: Math.round(2.5 * 1024 * 1024),
  expectedBytes: 1973430,
};
const DESKTOP_BASE = {
  width: 720,
  height: 405,
  fps: 3,
  count: 222,
  quality: 55,
  maxBytes: 8 * 1024 * 1024,
};
const DESKTOP_HIGH = {
  width: 1280,
  height: 720,
  fps: 12,
  count: 888,
  quality: 65,
  maxBytes: 48 * 1024 * 1024,
};

const packs = {
  desktop: DESKTOP_BASE,
  "desktop-high": DESKTOP_HIGH,
  mobile: MOBILE_LOCK,
};
const waypoints = (story.scrollMap || []).map((point) => point.time);
const priorDigest = story.frames?.digest;

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    ...options,
  });
  if (result.status !== 0) {
    throw new Error(
      `${command} ${args.join(" ")} failed: ${result.stderr || result.stdout || result.error}`,
    );
  }
  return result.stdout;
}

function probe(path) {
  return JSON.parse(
    run("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-of", "json", path]),
  );
}

function bytesOf(dir) {
  return readdirSync(dir)
    .filter((name) => name.endsWith(".webp"))
    .reduce((sum, name) => sum + statSync(join(dir, name)).size, 0);
}

function listFrames(dir) {
  return readdirSync(dir)
    .filter((fileName) => /^frame-\d{5}\.webp$/.test(fileName))
    .sort();
}

function exportPack(name, config, workRoot) {
  const outDir = join(workRoot, name);
  mkdirSync(outDir, { recursive: true });
  const pattern = join(outDir, "frame-%05d.webp");
  console.log(
    `Exporting ${name}: ${config.width}x${config.height} @ ${config.fps}fps q=${config.quality}`,
  );
  run("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-i",
    sourceMp4,
    "-an",
    "-vf",
    `fps=${config.fps},scale=${config.width}:${config.height}:flags=lanczos,setsar=1`,
    "-c:v",
    "libwebp",
    "-quality",
    String(config.quality),
    "-compression_level",
    "6",
    "-t",
    String(story.duration),
    "-start_number",
    "1",
    pattern,
  ]);
  const files = listFrames(outDir);
  assert.equal(files.length, config.count, `${name}: expected ${config.count}, got ${files.length}`);
  let bytes = 0;
  for (const file of files) bytes += statSync(join(outDir, file)).size;
  assert.ok(bytes <= config.maxBytes, `${name}: ${bytes} exceeds ${config.maxBytes}`);
  return { files, bytes, outDir };
}

function reuseOrExport(name, config, workRoot) {
  const priorDir =
    priorDigest && existsSync(join(webRoot, "public/assets", `cinematic-frames.${priorDigest}`, name))
      ? join(webRoot, "public/assets", `cinematic-frames.${priorDigest}`, name)
      : null;
  if (priorDir && (name === "desktop" || name === "mobile")) {
    const dest = join(workRoot, name);
    cpSync(priorDir, dest, { recursive: true });
    const files = listFrames(dest);
    assert.equal(files.length, config.count, `${name}: reused count mismatch`);
    const bytes = bytesOf(dest);
    console.log(`Reused ${name} from ${priorDigest} (${bytes} bytes)`);
    return { files, bytes, outDir: dest };
  }
  return exportPack(name, config, workRoot);
}

function compareWaypoint(sourcePath, framePath, frameIndex, fps) {
  const reference = join(tmpdir(), `mokaid-ref-${frameIndex}.png`);
  const candidate = join(tmpdir(), `mokaid-cand-${frameIndex}.png`);
  const zeroBased = frameIndex - 1;
  run("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-i",
    sourcePath,
    "-an",
    "-vf",
    `fps=${fps},scale=640:360:flags=lanczos,select=eq(n\\,${zeroBased})`,
    "-frames:v",
    "1",
    "-vsync",
    "vfr",
    reference,
  ]);
  run("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-i",
    framePath,
    "-frames:v",
    "1",
    "-vf",
    "scale=640:360:flags=lanczos",
    candidate,
  ]);
  const result = spawnSync(
    "ffmpeg",
    ["-hide_banner", "-i", reference, "-i", candidate, "-lavfi", "psnr", "-f", "null", "-"],
    { encoding: "utf8" },
  );
  const match = /average:([0-9.]+|inf)/.exec(result.stderr || "");
  const psnr = match?.[1] === "inf" ? Infinity : Number(match?.[1] || 0);
  rmSync(reference, { force: true });
  rmSync(candidate, { force: true });
  return psnr;
}

assert.ok(existsSync(sourceMp4), `Missing source film: ${sourceMp4}`);
const sourceMeta = probe(sourceMp4);
assert.ok(sourceMeta.streams.find((stream) => stream.codec_type === "video"));
assert.ok(Math.abs(Number(sourceMeta.format.duration) - story.duration) < 0.05);

const workRoot = join(tmpdir(), `mokaid-cinema-frames-${process.pid}`);
rmSync(workRoot, { recursive: true, force: true });
mkdirSync(workRoot, { recursive: true });

const packResults = {};
for (const [name, config] of Object.entries(packs)) {
  packResults[name] = { ...reuseOrExport(name, config, workRoot), ...config };
}

// Mobile lock: count/fps/width identical; bytes must match prior when reused.
assert.equal(packResults.mobile.count, MOBILE_LOCK.count);
assert.equal(packResults.mobile.fps, MOBILE_LOCK.fps);
assert.equal(packResults.mobile.width, MOBILE_LOCK.width);
if (priorDigest) {
  assert.equal(
    packResults.mobile.bytes,
    MOBILE_LOCK.expectedBytes,
    "Mobile pack bytes must remain identical to the locked release",
  );
}

const hash = createHash("sha256");
for (const name of Object.keys(packs)) {
  const { outDir, files } = packResults[name];
  for (const file of files) {
    hash.update(`${name}/${file}\0`);
    hash.update(readFileSync(join(outDir, file)));
  }
}
const digest = hash.digest("hex");
const short = digest.slice(0, 12);

for (const entry of readdirSync(join(webRoot, "public/assets"))) {
  if (entry.startsWith("cinematic-frames.")) {
    rmSync(join(webRoot, "public/assets", entry), { recursive: true, force: true });
  }
}

const publicDir = join(webRoot, "public/assets", `cinematic-frames.${short}`);
mkdirSync(publicDir, { recursive: true });
for (const [name, result] of Object.entries(packResults)) {
  const dest = join(publicDir, name);
  mkdirSync(dest, { recursive: true });
  for (const file of result.files) {
    copyFileSync(join(result.outDir, file), join(dest, file));
  }
}

const qualityReport = [];
for (const time of waypoints.slice(0, 6)) {
  const index = Math.min(
    DESKTOP_HIGH.count,
    Math.max(1, Math.round(time * DESKTOP_HIGH.fps) + 1),
  );
  const frameName = `frame-${String(index).padStart(5, "0")}.webp`;
  const framePath = join(publicDir, "desktop-high", frameName);
  assert.ok(existsSync(framePath), framePath);
  const frameTime = Math.min(story.duration - 0.05, (index - 1) / DESKTOP_HIGH.fps);
  const psnr = compareWaypoint(sourceMp4, framePath, index, DESKTOP_HIGH.fps);
  qualityReport.push({ time, frameTime, frame: frameName, psnrAverage: psnr, pack: "desktop-high" });
  assert.ok(psnr === Infinity || psnr >= 28, `PSNR too low at t=${time}: ${psnr}`);
}

const packMeta = (name, result) => ({
  pattern: `/assets/cinematic-frames.${short}/${name}/frame-%05d.webp`,
  firstIndex: 1,
  count: result.count,
  fps: result.fps,
  width: result.width,
  height: result.height,
  bytes: result.bytes,
});

const frames = {
  digest: short,
  sha256: digest,
  quality: {
    desktop: { base: DESKTOP_BASE.quality, high: DESKTOP_HIGH.quality },
    mobile: MOBILE_LOCK.quality,
  },
  desktop: {
    base: packMeta("desktop", packResults.desktop),
    high: packMeta("desktop-high", packResults["desktop-high"]),
  },
  mobile: packMeta("mobile", packResults.mobile),
};

const nextStory = { ...story, frames };
delete nextStory.video;
writeFileSync(storyPath, `${JSON.stringify(nextStory, null, 2)}\n`);

const reportDir = join(repoRoot, "artifacts/mokaid-cinema-2026-09-28");
mkdirSync(join(reportDir, "verification"), { recursive: true });
writeFileSync(
  join(reportDir, "verification/frame-export.json"),
  `${JSON.stringify({ sourceMp4, frames, qualityReport, publicDir }, null, 2)}\n`,
);

rmSync(workRoot, { recursive: true, force: true });
console.log(
  JSON.stringify(
    {
      digest: short,
      desktopBaseBytes: frames.desktop.base.bytes,
      desktopHighBytes: frames.desktop.high.bytes,
      mobileBytes: frames.mobile.bytes,
      qualityReport,
      publicDir,
    },
    null,
    2,
  ),
);
