/** Recover genuine high-resolution character detail without changing the rig,
 * UVs, outfit colors, or artist-specific recolored variants. Run before any
 * expression / geometry preparation that changes the pinned source document.
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, resolve, relative, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '../../../..');
export const characterTextureSources = Object.freeze(JSON.parse(
  await readFile(resolve(repository, 'assets/character-textures/provenance.json'), 'utf8'),
).sources);
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

export function characterUvHash(document) {
  const hash = createHash('sha256');
  for (const mesh of document.getRoot().listMeshes()) {
    for (const primitive of mesh.listPrimitives()) {
      if (!primitive.getMaterial()?.getBaseColorTexture()) continue;
      const uv = primitive.getAttribute('TEXCOORD_0');
      if (!uv) throw Error('Character texture recovery requires authored TEXCOORD_0');
      const array = uv.getArray();
      hash.update(Buffer.from(array.buffer, array.byteOffset, array.byteLength));
    }
  }
  return hash.digest('hex');
}

function sourceFor(key) {
  // Female is the backend's legacy design slug. Byte, Nyx and Moss have
  // separately painted atlases and deliberately have no recovery entry.
  return characterTextureSources[key === 'avatar_female' ? 'avatar_design' : key];
}
function assetPath(repoRoot, path) {
  const target = resolve(repoRoot, path), fromRoot = relative(repoRoot, target);
  if (isAbsolute(path) || fromRoot.startsWith('..') || isAbsolute(fromRoot))
    throw Error('Character texture provenance path must stay inside the repository');
  return target;
}

/** Apply one reviewed atlas. Exported separately so the trust boundary can be
 * tested with small synthetic images, without loading production character rigs.
 */
export async function applyVerifiedCharacterTexture(document, source, { sourceSha256, image }) {
  if (sourceSha256 !== source.catalogSourceSha256) return null;
  const texture = document.getRoot().listMaterials()
    .map(material => material.getBaseColorTexture()).filter(Boolean)
    .find(candidate => sha256(candidate.getImage()) === source.catalogImageSha256);
  if (!texture) throw Error('Catalog character image changed: review texture recovery provenance');
  if (characterUvHash(document) !== source.catalogUvSha256)
    throw Error('Catalog character UV layout changed: review texture recovery provenance');
  if (sha256(image) !== source.sha256)
    throw Error('Recovered character atlas hash mismatch');
  const [before, after] = await Promise.all([sharp(texture.getImage()).metadata(), sharp(image).metadata()]);
  if (after.width !== source.width || after.height !== source.height
      || after.width > source.original.width || after.height > source.original.height
      || after.width <= before.width || after.height <= before.height)
    throw Error('Recovered character atlas must contain verified additional source resolution');
  // Verify everything before mutating the shared texture. Geometry, material
  // factors, other maps, and texture-coordinate bindings remain untouched.
  texture.setImage(new Uint8Array(image)).setMimeType(source.mimeType);
  return {
    path: source.path, sha256: source.sha256,
    sourceImageSha256: source.catalogImageSha256,
    originalImageSha256: source.original.imageSha256,
    originalSourceSha256: source.original.sha256,
    originalResolution: [source.original.width, source.original.height],
    resolution: [source.width, source.height],
  };
}

/** Default runtime cooker path reads only the small checked-in recovered atlas.
 * Original multi-megabyte GLBs are authoring provenance, never a CI dependency.
 * An unmapped revision is preserved, as are all custom / recolored characters.
 */
export async function restoreCharacterTextures(document, key, { sourceSha256, repoRoot = repository }) {
  const source = sourceFor(key);
  if (!source || sourceSha256 !== source.catalogSourceSha256) return null;
  const image = await readFile(assetPath(repoRoot, source.path));
  return applyVerifiedCharacterTexture(document, source, { sourceSha256, image });
}

export function embeddedGlbImage(bytes, imageIndex) {
  if (bytes.length < 20 || bytes.readUInt32LE(0) !== 0x46546c67
      || bytes.readUInt32LE(4) !== 2 || bytes.readUInt32LE(8) !== bytes.length)
    throw Error('Invalid original character GLB');
  let document, binary;
  for (let offset = 12; offset < bytes.length;) {
    if (offset + 8 > bytes.length) throw Error('Truncated original GLB chunk');
    const length = bytes.readUInt32LE(offset), type = bytes.readUInt32LE(offset + 4);
    if (offset + 8 + length > bytes.length) throw Error('Truncated original GLB data');
    const chunk = bytes.subarray(offset + 8, offset + 8 + length);
    if (type === 0x4e4f534a) document = JSON.parse(chunk.toString('utf8'));
    else if (type === 0x004e4942) binary = chunk;
    offset += 8 + length;
  }
  const image = document?.images?.[imageIndex], view = document?.bufferViews?.[image?.bufferView];
  if (!binary || !view || image.uri || (view.buffer ?? 0) !== 0
      || !Number.isSafeInteger(view.byteOffset ?? 0) || (view.byteOffset ?? 0) < 0
      || !Number.isSafeInteger(view.byteLength) || view.byteLength < 1
      || (view.byteOffset ?? 0) + view.byteLength > binary.length)
    throw Error('Original character image must be an embedded valid GLB buffer view');
  return binary.subarray(view.byteOffset ?? 0, (view.byteOffset ?? 0) + view.byteLength);
}

/** Optional offline rebake from the pinned artist GLB; never enlarges a source.
 * Sharp's pinned version and explicit lossless WebP options make the output reviewable.
 */
export async function bakeOriginalCharacterAtlas(bytes, source) {
  if (sha256(bytes) !== source.original.sha256) throw Error('Original character GLB hash mismatch');
  const image = embeddedGlbImage(bytes, source.original.imageIndex);
  if (sha256(image) !== source.original.imageSha256) throw Error('Original character image hash mismatch');
  const metadata = await sharp(image).metadata();
  if (metadata.width !== source.original.width || metadata.height !== source.original.height
      || source.width > metadata.width || source.height > metadata.height)
    throw Error('Original character resolution mismatch');
  const output = await sharp(image)
    .resize({ width: source.width, height: source.height, fit: 'inside', withoutEnlargement: true, kernel: 'lanczos3' })
    .webp({ lossless: true, effort: 6 }).toBuffer();
  if (sha256(output) !== source.sha256) throw Error('Rebaked character image changed: review the pinned conversion');
  return output;
}

// Explicit authoring command only. The regular cooker never touches raw GLBs.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv.length !== 3 || process.argv[2] !== '--bake')
    throw Error('Usage: node character-textures.mjs --bake');
  for (const [key, source] of Object.entries(characterTextureSources)) {
    const output = await bakeOriginalCharacterAtlas(await readFile(assetPath(repository, source.original.path)), source);
    const target = assetPath(repository, source.path);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, output);
    console.log(`${key}: ${source.width}×${source.height} original atlas recovered`);
  }
}
