#!/usr/bin/env npx tsx
/**
 * Generates the production asset manifest from a directory of optimized GLB
 * files. The output replaces the procedural entries in
 * apps/web/src/three/asset-manifest.ts once final 3D assets are delivered.
 *
 * Usage: npx tsx scripts/generate-asset-manifest.ts <assets_dir> [cdn_base_url]
 */

import { createHash } from "node:crypto";
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, basename } from "node:path";

const assetsDir = process.argv[2] ?? "assets/optimized";
const cdnBase = process.argv[3] ?? "https://assets.mokaid.app";

if (!existsSync(assetsDir)) {
  console.log(`No assets directory at ${assetsDir} — final 3D assets not delivered yet.`);
  process.exit(0);
}

const files = readdirSync(assetsDir).filter((f) => f.endsWith(".glb"));

const manifest = Object.fromEntries(
  files.map((file) => {
    const content = readFileSync(join(assetsDir, file));
    const hash = createHash("sha256").update(content).digest("hex").slice(0, 12);
    const id = basename(file, ".glb");

    return [
      id,
      {
        id,
        url: `${cdnBase}/assets3d/${id}.${hash}.glb`,
        bytes: content.length,
        sha256: hash,
      },
    ];
  }),
);

const outPath = join(assetsDir, "manifest.json");
writeFileSync(outPath, JSON.stringify(manifest, null, 2));
console.log(`Wrote ${files.length} entries to ${outPath}`);
