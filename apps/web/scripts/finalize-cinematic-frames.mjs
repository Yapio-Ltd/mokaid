#!/usr/bin/env node
/** Finalize story JSON from an already-exported multi-tier frame pack. */
import assert from "node:assert/strict";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(here, "..");
const repoRoot = resolve(webRoot, "../..");
const short = process.argv[2];
assert.ok(short, "Usage: finalize-cinematic-frames.mjs <digest12>");
const publicDir = join(webRoot, "public/assets", `cinematic-frames.${short}`);
const storyPath = join(webRoot, "src/data/cinematic-story.json");
const story = JSON.parse(readFileSync(storyPath, "utf8"));

function bytesOf(dir) {
  return readdirSync(dir)
    .filter((name) => name.endsWith(".webp"))
    .reduce((sum, name) => sum + statSync(join(dir, name)).size, 0);
}

function packMeta(name, config) {
  const dir = join(publicDir, name);
  assert.ok(existsSync(dir), dir);
  const count = readdirSync(dir).filter((n) => n.endsWith(".webp")).length;
  assert.equal(count, config.count, `${name} count`);
  return {
    pattern: `/assets/cinematic-frames.${short}/${name}/frame-%05d.webp`,
    firstIndex: 1,
    count: config.count,
    fps: config.fps,
    width: config.width,
    height: config.height,
    bytes: bytesOf(dir),
  };
}

assert.ok(existsSync(publicDir), `Missing pack ${publicDir}`);

const desktopBase = { width: 720, height: 405, fps: 3, count: 222, quality: 55 };
const desktopHigh = { width: 1280, height: 720, fps: 12, count: 888, quality: 65 };
const mobile = { width: 480, height: 270, fps: 2, count: 148, quality: 50 };

const frames = {
  digest: short,
  quality: {
    desktop: { base: desktopBase.quality, high: desktopHigh.quality },
    mobile: mobile.quality,
  },
  desktop: {
    base: packMeta("desktop", desktopBase),
    high: packMeta("desktop-high", desktopHigh),
  },
  mobile: packMeta("mobile", mobile),
};

assert.equal(frames.mobile.bytes, 1973430, "Mobile pack must stay byte-locked");

const nextStory = { ...story, frames };
delete nextStory.video;
writeFileSync(storyPath, `${JSON.stringify(nextStory, null, 2)}\n`);

const reportDir = join(repoRoot, "artifacts/mokaid-cinema-2026-09-28/verification");
mkdirSync(reportDir, { recursive: true });
writeFileSync(join(reportDir, "frame-export.json"), `${JSON.stringify({ frames, publicDir }, null, 2)}\n`);
console.log(JSON.stringify({ frames }, null, 2));
