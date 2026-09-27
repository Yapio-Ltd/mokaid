#!/usr/bin/env node
/**
 * Export dual WebP frame packs from the cinematic master for scroll scrubbing.
 * Desktop: 1280x720 @ 24fps. Mobile: 960x540 @ 12fps.
 */
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
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
  join(webRoot, "public/assets/mokaid-office-journey.adac1c365481.mp4");
const quality = Number(process.env.MOKAID_WEBP_QUALITY || 84);
const packs = {
  desktop: { width: 1280, height: 720, fps: 24, count: 1776 },
  mobile: { width: 960, height: 540, fps: 12, count: 888 },
};
const waypoints = (story.scrollMap || []).map((point) => point.time);

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

function exportPack(name, config, workRoot) {
  const outDir = join(workRoot, name);
  mkdirSync(outDir, { recursive: true });
  // image2 sequence numbering is 1-based (frame-00001 … frame-N).
  const pattern = join(outDir, "frame-%05d.webp");
  console.log(`Exporting ${name}: ${config.width}x${config.height} @ ${config.fps}fps q=${quality}`);
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
    String(quality),
    "-compression_level",
    "4",
    "-t",
    String(story.duration),
    "-start_number",
    "1",
    pattern,
  ]);
  const files = readdirSync(outDir)
    .filter((name) => /^frame-\d{5}\.webp$/.test(name))
    .sort();
  assert.equal(
    files.length,
    config.count,
    `${name}: expected ${config.count} frames, got ${files.length}`,
  );
  assert.equal(files[0], "frame-00001.webp");
  assert.equal(files[files.length - 1], `frame-${String(config.count).padStart(5, "0")}.webp`);
  let bytes = 0;
  for (const file of files) bytes += statSync(join(outDir, file)).size;
  return { files, bytes, outDir };
}

function compareWaypoint(sourcePath, framePath, time) {
  const reference = join(tmpdir(), `mokaid-ref-${time}.png`);
  const candidate = join(tmpdir(), `mokaid-cand-${time}.png`);
  run("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-ss",
    String(time),
    "-i",
    sourcePath,
    "-frames:v",
    "1",
    "-vf",
    "scale=640:360:flags=lanczos",
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
  // stderr holds the psnr line; fail only on catastrophic mismatch.
  const result = spawnSync(
    "ffmpeg",
    [
      "-hide_banner",
      "-i",
      reference,
      "-i",
      candidate,
      "-lavfi",
      "psnr",
      "-f",
      "null",
      "-",
    ],
    { encoding: "utf8" },
  );
  const match = /average:([0-9.]+|inf)/.exec(result.stderr || "");
  const raw = match?.[1];
  const psnr = raw === "inf" ? Infinity : Number(raw || 0);
  rmSync(reference, { force: true });
  rmSync(candidate, { force: true });
  return psnr;
}

assert.ok(existsSync(sourceMp4), `Missing source film: ${sourceMp4}`);
const sourceMeta = probe(sourceMp4);
const sourceVideo = sourceMeta.streams.find((stream) => stream.codec_type === "video");
assert.ok(sourceVideo, "Source has no video stream");
assert.ok(Math.abs(Number(sourceMeta.format.duration) - story.duration) < 0.05, "Duration mismatch");

const workRoot = join(tmpdir(), `mokaid-cinema-frames-${process.pid}`);
rmSync(workRoot, { recursive: true, force: true });
mkdirSync(workRoot, { recursive: true });

const packResults = {};
for (const [name, config] of Object.entries(packs)) {
  packResults[name] = { ...exportPack(name, config, workRoot), ...config };
}

// Fingerprint over sorted relative paths + contents for stable digest.
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
const publicDir = join(webRoot, "public/assets", `cinematic-frames.${short}`);
rmSync(publicDir, { recursive: true, force: true });
mkdirSync(publicDir, { recursive: true });

for (const [name, result] of Object.entries(packResults)) {
  const dest = join(publicDir, name);
  mkdirSync(dest, { recursive: true });
  for (const file of result.files) {
    copyFileSync(join(result.outDir, file), join(dest, file));
  }
}

// Quality sample at scroll waypoints using desktop pack (map time → frame).
const qualityReport = [];
for (const time of waypoints.slice(0, 6)) {
  // Map story seconds → 1-based frame number at the pack fps.
  const index = Math.min(
    packs.desktop.count,
    Math.max(1, Math.round(time * packs.desktop.fps) + 1),
  );
  const frameName = `frame-${String(index).padStart(5, "0")}.webp`;
  const framePath = join(publicDir, "desktop", frameName);
  assert.ok(existsSync(framePath), `Missing quality sample frame ${framePath}`);
  const psnr = compareWaypoint(sourceMp4, framePath, Math.min(time, story.duration - 0.05));
  qualityReport.push({ time, frame: frameName, psnrAverage: psnr });
  // Below ~28 dB would be visibly broken at 640px; photographic WebP is typically 35+.
  assert.ok(psnr === Infinity || psnr >= 28, `PSNR too low at t=${time}: ${psnr}`);
}

const frames = {
  digest: short,
  sha256: digest,
  quality,
  desktop: {
    pattern: `/assets/cinematic-frames.${short}/desktop/frame-%05d.webp`,
    firstIndex: 1,
    count: packs.desktop.count,
    fps: packs.desktop.fps,
    width: packs.desktop.width,
    height: packs.desktop.height,
    bytes: packResults.desktop.bytes,
  },
  mobile: {
    pattern: `/assets/cinematic-frames.${short}/mobile/frame-%05d.webp`,
    firstIndex: 1,
    count: packs.mobile.count,
    fps: packs.mobile.fps,
    width: packs.mobile.width,
    height: packs.mobile.height,
    bytes: packResults.mobile.bytes,
  },
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

// Remove the large runtime MP4 once packs exist (master retained under artifacts).
const runtimeMp4 = join(webRoot, "public/assets/mokaid-office-journey.adac1c365481.mp4");
if (existsSync(runtimeMp4)) {
  const archive = join(repoRoot, "artifacts/mokaid-cinema-2026-09-25/deliveries");
  mkdirSync(archive, { recursive: true });
  const archived = join(archive, "mokaid-office-journey.adac1c365481.mp4");
  if (!existsSync(archived)) copyFileSync(runtimeMp4, archived);
  rmSync(runtimeMp4);
}

rmSync(workRoot, { recursive: true, force: true });
console.log(
  JSON.stringify(
    {
      digest: short,
      desktopBytes: frames.desktop.bytes,
      mobileBytes: frames.mobile.bytes,
      qualityReport,
      publicDir,
    },
    null,
    2,
  ),
);
