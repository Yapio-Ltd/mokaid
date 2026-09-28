#!/usr/bin/env node
/**
 * Export dual WebP frame packs from the cinematic master for scroll scrubbing.
 * Desktop: 720x405 @ 3fps. Mobile: 480x270 @ 2fps. Slim budgets for progressive TTI.
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
const packs = {
  desktop: {
    width: 720,
    height: 405,
    fps: 3,
    count: 222,
    quality: 55,
    maxBytes: 8 * 1024 * 1024,
  },
  mobile: {
    width: 480,
    height: 270,
    fps: 2,
    count: 148,
    quality: 50,
    maxBytes: Math.round(2.5 * 1024 * 1024),
  },
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
  const files = readdirSync(outDir)
    .filter((fileName) => /^frame-\d{5}\.webp$/.test(fileName))
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
  assert.ok(
    bytes <= config.maxBytes,
    `${name}: pack ${bytes} bytes exceeds budget ${config.maxBytes}`,
  );
  return { files, bytes, outDir };
}

function compareWaypoint(sourcePath, framePath, frameIndex, fps) {
  const reference = join(tmpdir(), `mokaid-ref-${frameIndex}.png`);
  const candidate = join(tmpdir(), `mokaid-cand-${frameIndex}.png`);
  // Extract the exact same fps-subsampled frame the pack used (select by 0-based index).
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

// Remove previous frame packs under public/assets.
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
    packs.desktop.count,
    Math.max(1, Math.round(time * packs.desktop.fps) + 1),
  );
  const frameName = `frame-${String(index).padStart(5, "0")}.webp`;
  const framePath = join(publicDir, "desktop", frameName);
  assert.ok(existsSync(framePath), `Missing quality sample frame ${framePath}`);
  const frameTime = Math.min(story.duration - 0.05, (index - 1) / packs.desktop.fps);
  const psnr = compareWaypoint(sourceMp4, framePath, index, packs.desktop.fps);
  qualityReport.push({ time, frameTime, frame: frameName, psnrAverage: psnr });
  // Round-trip vs same fps subsample: WebP q55 should stay comfortably above 28 dB.
  assert.ok(psnr === Infinity || psnr >= 28, `PSNR too low at t=${time}: ${psnr}`);
}

const frames = {
  digest: short,
  sha256: digest,
  quality: {
    desktop: packs.desktop.quality,
    mobile: packs.mobile.quality,
  },
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
