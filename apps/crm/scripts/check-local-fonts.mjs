import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const fontRoot = path.join(root, "public/fonts");
const manifest = JSON.parse(await readFile(path.join(fontRoot, "sources.json"), "utf8"));
const css = await readFile(path.join(root, "src/app/fonts.css"), "utf8");
const bundled = new Map(manifest.fonts.map((font) => [font.file, font]));
const referenced = new Set();

// Fail before Next runs if a font is missing, corrupt, or unexpectedly remote.
for (const [, url] of css.matchAll(/url\(([^)]+)\)/g)) {
  assert.match(url, /^\/fonts\/[a-z0-9-]+\.woff2$/);
  const filename = url.slice("/fonts/".length);
  assert.ok(bundled.has(filename), `Untracked font: ${filename}`);
  referenced.add(filename);
}
assert.equal(referenced.size, bundled.size, "Font manifest and stylesheet differ");

for (const [filename, font] of bundled) {
  assert.equal(new URL(font.sourceUrl).origin, "https://fonts.gstatic.com");
  const bytes = await readFile(path.join(fontRoot, filename));
  assert.equal(bytes.subarray(0, 4).toString("ascii"), "wOF2", filename);
  assert.equal(bytes.readUInt32BE(8), bytes.length, filename);
  assert.equal(bytes.length, font.bytes, filename);
  assert.equal(createHash("sha256").update(bytes).digest("hex"), font.sha256, filename);
}

for (const family of ["ibm-plex-sans", "ibm-plex-mono", "source-serif-4"]) {
  const license = await readFile(path.join(fontRoot, `${family}-OFL.txt`), "utf8");
  assert.ok(license.includes("SIL OPEN FONT LICENSE Version 1.1"), family);
}

async function checkSource(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const filename = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      await checkSource(filename);
    } else if (/\.[cm]?[jt]sx?$/.test(entry.name)) {
      const source = await readFile(filename, "utf8");
      assert.ok(!/(?:from\s*|import\s*\(|require\s*\()\s*["']next\/font\/google["']/.test(source),
        `Remote font loader reintroduced: ${path.relative(root, filename)}`);
    }
  }
}
await checkSource(path.join(root, "src"));
console.log(`Verified ${bundled.size} local WOFF2 files, provenance and OFL licenses; no remote font loader.`);
