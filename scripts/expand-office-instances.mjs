/**
 * Expand EXT_mesh_gpu_instancing into discrete nodes.
 * Same visual result; safer on Windows Chrome/ANGLE than GPU instancing +
 * quantized attributes. Also runs dequantize() so float POSITION/NORMAL
 * are guaranteed even if the caller skipped the CLI step.
 *
 * Usage: node scripts/expand-office-instances.mjs <in.glb> <out.glb>
 *
 * Dependencies (npx): @gltf-transform/core, extensions, functions
 */
import { NodeIO } from "@gltf-transform/core";
import {
  ALL_EXTENSIONS,
  EXTMeshGPUInstancing,
} from "@gltf-transform/extensions";
import { dequantize, prune } from "@gltf-transform/functions";
import { writeFileSync } from "node:fs";

const [, , input, output] = process.argv;
if (!input || !output) {
  console.error(
    "Usage: node scripts/expand-office-instances.mjs <in.glb> <out.glb>",
  );
  process.exit(1);
}

const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const document = await io.read(input);

await document.transform(dequantize());

const root = document.getRoot();
const instExt = document.createExtension(EXTMeshGPUInstancing);

function readVec3(accessor, i) {
  const arr = accessor.getArray();
  const o = i * 3;
  return [arr[o], arr[o + 1], arr[o + 2]];
}

function readVec4(accessor, i) {
  const arr = accessor.getArray();
  const o = i * 4;
  return [arr[o], arr[o + 1], arr[o + 2], arr[o + 3]];
}

let expanded = 0;
for (const node of [...root.listNodes()]) {
  const inst = node.getExtension("EXT_mesh_gpu_instancing");
  if (!inst) continue;

  const translation = inst.getAttribute("TRANSLATION");
  const rotation = inst.getAttribute("ROTATION");
  const scale = inst.getAttribute("SCALE");
  const count =
    translation?.getCount() ??
    rotation?.getCount() ??
    scale?.getCount() ??
    0;

  if (count <= 0) {
    node.setExtension("EXT_mesh_gpu_instancing", null);
    continue;
  }

  const mesh = node.getMesh();
  const baseName = node.getName() || "instance";
  // Spec: world = nodeWorld * instanceLocal — keep parent TRS, put mesh on children.
  for (let i = 0; i < count; i++) {
    const clone = document.createNode(`${baseName}_${i}`);
    if (mesh) clone.setMesh(mesh);
    if (translation) clone.setTranslation(readVec3(translation, i));
    if (rotation) clone.setRotation(readVec4(rotation, i));
    if (scale) clone.setScale(readVec3(scale, i));
    node.addChild(clone);
    expanded++;
  }

  node.setMesh(null);
  node.setExtension("EXT_mesh_gpu_instancing", null);
}

instExt.dispose();
await document.transform(prune());

const out = await io.writeBinary(document);
writeFileSync(output, out);
console.log(
  `Expanded ${expanded} instances → ${output} (${(out.byteLength / 1e6).toFixed(2)} MB)`,
);
