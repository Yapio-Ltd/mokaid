/** Read-only asset inspection. Run from any cwd; --candidate accepts a desktop GLB. */
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '../..');
const require = createRequire(resolve(repo, 'apps/desktop/tools/asset-cooker/package.json'));
const { NodeIO } = require('@gltf-transform/core');
const { ALL_EXTENSIONS } = require('@gltf-transform/extensions');
const draco = require('draco3dgltf');
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS).registerDependencies({
  'draco3d.decoder': await draco.createDecoderModule(),
});
const args = process.argv.slice(2);
const option = (name) => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
const assetSource = await readFile(resolve(repo, 'apps/web/src/three/office-asset.ts'), 'utf8');
const source = resolve(repo, 'apps/web/public', assetSource.match(/OFFICE_ENVIRONMENT_CDN_PATH\s*=\s*"([^"]+)"/)[1].slice(1));
const cameraSource = await readFile(resolve(repo, 'apps/desktop/engine/include/mokaid/engine/office_camera.hpp'), 'utf8');
const qmlSource = await readFile(resolve(repo, 'apps/desktop/presentation/qml/OfficePage.qml'), 'utf8');
const cameraMatch = cameraSource.match(/normalized\(\{([\d.]+)F, ([\d.]+)F - ([\d.]+)F \* wide, -([\d.]+)F\}\)/);
const rangeMatch = cameraSource.match(/\(aspect - ([\d.]+)F\) \/ ([\d.]+)F/);
const scaleMatch = cameraSource.match(/const float scale = ([\d.]+)F \/ std::max/);
if (!cameraMatch || !rangeMatch || !scaleMatch) throw Error('Camera profile changed; update the explicit numerical mirror before comparing');
const currentCamera = {
  x: Number(cameraMatch[1]), y: Number(cameraMatch[2]), wideDrop: Number(cameraMatch[3]), z: -Number(cameraMatch[4]),
  aspectStart: Number(rangeMatch[1]), aspectSpan: Number(rangeMatch[2]), silhouetteSpan: Number(scaleMatch[1]),
  topMargin: Number(qmlSource.match(/anchors.topMargin:\s*(\d+)/)[1]),
  bottomMargin: Number(qmlSource.match(/anchors.bottomMargin:\s*(\d+)/)[1]),
  sourceSha256: createHash('sha256').update(cameraSource).digest('hex'),
};
const range = (points, k) => points.reduce(([lo, hi], p) => [Math.min(lo, p[k]), Math.max(hi, p[k])], [Infinity, -Infinity]);
const dot = (a, b) => a.reduce((sum, value, k) => sum + value * b[k], 0);
const sub = (a, b) => a.map((value, k) => value - b[k]);
const norm = (v) => { const n = Math.hypot(...v); return v.map((value) => value / n); };
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const rounded = (value) => Math.round(value * 10000) / 10000;
const transform = (m, v) => [
  -(m[0] * v[0] + m[4] * v[1] + m[8] * v[2] + m[12]),
  m[1] * v[0] + m[5] * v[1] + m[9] * v[2] + m[13],
  -(m[2] * v[0] + m[6] * v[1] + m[10] * v[2] + m[14]),
];

async function inspect(path) {
  const bytes = await readFile(path);
  const document = await io.readBinary(bytes);
  const points = [], meshRows = [], floorTriangles = [], chairs = [];
  let triangleCount = 0, degenerateTriangleCount = 0, nonFinitePositionCount = 0;
  for (const node of document.getRoot().listNodes()) {
    if (!node.getMesh()) continue;
    if (node.getExtension('EXT_mesh_gpu_instancing')) throw Error('Expand instancing before geometry inspection');
    const matrix = node.getWorldMatrix();
    let diagonalMax = -Infinity;
    const materials = [], nodePoints = [];
    const cushion = { triangles: 0, area: 0, weightedCenter: [0, 0, 0] };
    for (const primitive of node.getMesh().listPrimitives()) {
      const material = primitive.getMaterial()?.getName() || '';
      materials.push(material);
      const positions = primitive.getAttribute('POSITION');
      const vertices = [];
      for (let i = 0; i < positions.getCount(); i++) {
        const point = transform(matrix, positions.getElement(i, []));
        vertices.push(point); points.push(point); nodePoints.push(point);
        if (!point.every(Number.isFinite)) nonFinitePositionCount++;
        diagonalMax = Math.max(diagonalMax, point[0] - point[2]);
      }
      const indices = primitive.getIndices();
      for (let i = 0; i < (indices?.getCount() || vertices.length); i += 3) {
        const triangle = [0, 1, 2].map((k) => vertices[indices ? indices.getScalar(i + k) : i + k]);
        if (triangle.some(point => !point)) throw Error(`Out-of-range triangle index in ${node.getName()}`);
        const normal = cross(sub(triangle[1], triangle[0]), sub(triangle[2], triangle[0]));
        const twiceArea = Math.hypot(...normal);
        triangleCount++;
        if (twiceArea < 1e-10) degenerateTriangleCount++;
        if (material === 'base' && triangle.every((point) => Math.abs(point[1]) < .005)) floorTriangles.push(triangle);
        if (node.getName() === 'chair_5' && /Leather/i.test(material)
            && triangle.every(point => point[1] > .45 && point[1] < .65)
            && normal[1] / twiceArea > .7) {
          const area = twiceArea / 2;
          cushion.triangles++;
          cushion.area += area;
          cushion.weightedCenter = cushion.weightedCenter.map((value, k) => value + area * triangle.reduce((sum, point) => sum + point[k], 0) / 3);
        }
      }
    }
    if (/^chair_\d+$/.test(node.getName())) chairs.push({
      name: node.getName(), materials,
      bounds: { min: [0,1,2].map(k => rounded(range(nodePoints,k)[0])), max: [0,1,2].map(k => rounded(range(nodePoints,k)[1])) },
      ...(cushion.area > 0 ? { cushion: { upwardTriangles: cushion.triangles, area: rounded(cushion.area), centroid: cushion.weightedCenter.map(value => value / cushion.area) } } : {}),
    });
    meshRows.push({ name: node.getName(), materials, maxNativeXMinusZ: rounded(diagonalMax) });
  }
  const min = [0, 1, 2].map((k) => range(points, k)[0]);
  const max = [0, 1, 2].map((k) => range(points, k)[1]);
  const edges = new Map();
  let floorArea = 0;
  for (const triangle of floorTriangles) {
    const area = cross(sub(triangle[1], triangle[0]), sub(triangle[2], triangle[0]));
    floorArea += Math.abs(area[1]) / 2;
    for (let i = 0; i < 3; i++) {
      const key = [triangle[i], triangle[(i + 1) % 3]]
        .map((point) => JSON.stringify([rounded(point[0]), rounded(point[2])])).sort().join('|');
      edges.set(key, (edges.get(key) || 0) + 1);
    }
  }
  return { points, min, max, report: {
    path, sha256: createHash('sha256').update(bytes).digest('hex'),
    coordinates: 'Native right-handed Y-up: (-glTF.x, glTF.y, -glTF.z)',
    bounds: { min: min.map(rounded), max: max.map(rounded) },
    meshCount: meshRows.length, triangleCount, degenerateTriangleCount, nonFinitePositionCount,
    textureHashes: document.getRoot().listTextures().map(texture => ({
      name: texture.getName(), sha256: createHash('sha256').update(texture.getImage()).digest('hex'),
    })),
    materialTextureBindings: document.getRoot().listMaterials().map(material => ({
      name: material.getName(),
      textures: Object.fromEntries(['BaseColor','Emissive','Normal','MetallicRoughness','Occlusion'].map(slot => {
        const texture = material[`get${slot}Texture`]();
        return [slot, texture ? createHash('sha256').update(texture.getImage()).digest('hex') : null];
      })),
    })),
    chairs: chairs.sort((a,b) => a.name.localeCompare(b.name)),
    floorArea: rounded(floorArea),
    floorBorderNativeXZ: [...edges].filter(([, count]) => count === 1).map(([key]) => key.split('|').map(JSON.parse)),
    diagonalExtremes: meshRows.sort((a, b) => b.maxNativeXMinusZ - a.maxNativeXMinusZ).slice(0, 12),
  } };
}

function project(geometry, width, height, mode) {
  const aspect = width / height;
  const blend = Math.max(0, Math.min(1, (aspect - currentCamera.aspectStart) / currentCamera.aspectSpan));
  const back = mode === 'baseline' ? norm([7.256, 7.32, -13.704])
    : norm([currentCamera.x, currentCamera.y - currentCamera.wideDrop * blend, currentCamera.z]);
  const elevation = Math.asin(back[1]);
  const azimuth = Math.atan2(back[0], -back[2]);
  const right = norm(cross([0, 1, 0], back));
  const up = cross(back, right);
  const target = geometry.min.map((value, k) => (value + geometry.max[k]) * .5);
  const tangent = Math.tan(.5 * .5);
  const fitMargin = .94;
  let distance = 1;
  for (let corner = 0; corner < 8; corner++) {
    const p = [0, 1, 2].map((k) => corner & (1 << k) ? geometry.max[k] : geometry.min[k]);
    const relative = sub(p, target);
    distance = Math.max(distance, dot(relative, back) + Math.max(
      Math.abs(dot(relative, right)) / (tangent * aspect * fitMargin),
      Math.abs(dot(relative, up)) / (tangent * fitMargin)));
  }
  const projected = geometry.points.map((point) => {
    const relative = sub(point, target), depth = distance - dot(relative, back);
    return [dot(relative, right) / (depth * tangent * aspect), dot(relative, up) / (depth * tangent)];
  });
  const ranges = [0, 1].map((k) => range(projected, k));
  const spans = ranges.map(([lo, hi]) => hi - lo);
  const scale = (mode === 'baseline' ? 1.88 : currentCamera.silhouetteSpan) / Math.max(...spans);
  const pixels = [spans[0] * scale * width / 2, spans[1] * scale * height / 2];
  return { mode, viewport: [width, height], aspect: rounded(aspect), elevationDegrees: rounded(elevation * 180 / Math.PI),
    azimuthDegrees: rounded(azimuth * 180 / Math.PI), silhouettePixels: pixels.map(rounded),
    sideMarginPixels: rounded((width - pixels[0]) / 2), topMarginPixels: rounded((height - pixels[1]) / 2),
    widthFill: rounded(pixels[0] / width), heightFill: rounded(pixels[1] / height), fitDistance: rounded(distance) };
}

const baseline = await inspect(source);
const candidatePath = option('--candidate');
const candidate = candidatePath ? await inspect(resolve(candidatePath)) : baseline;
const configurations = [
  { name: 'Existing desktop', width: 1063, height: 469, mode: 'baseline', geometry: baseline },
  { name: 'Current desktop', width: 1063, height: 665 - currentCamera.topMargin - currentCamera.bottomMargin, mode: 'current', geometry: candidate },
  { name: 'Existing desktop with chat', width: 653, height: 469, mode: 'baseline', geometry: baseline },
  { name: 'Current desktop with chat', width: 653, height: 665 - currentCamera.topMargin - currentCamera.bottomMargin, mode: 'current', geometry: candidate },
];
const report = {
  note: 'Offline silhouette analysis, not a GPU screenshot or runtime acceptance test. Current camera values and QML margins are read directly from production sources. Source geometry projects all vertices with the same perspective fit and recenter calculation as native code.',
  currentCamera,
  baseline: baseline.report, candidate: candidatePath ? candidate.report : null,
  cameraComparisons: configurations.map(({ name, width, height, mode, geometry }) => ({ name, ...project(geometry, width, height, mode) })),
};
if (candidatePath) {
  const originalMaterials = new Map(baseline.report.materialTextureBindings.map(material => [material.name,material.textures]));
  report.assetChecks = {
    textureBytesPreserved: JSON.stringify(baseline.report.textureHashes.map(texture=>texture.sha256).sort())
      === JSON.stringify(candidate.report.textureHashes.map(texture=>texture.sha256).sort()),
    originalMaterialTextureBindingChanges: candidate.report.materialTextureBindings
      .filter(material => originalMaterials.has(material.name) && JSON.stringify(originalMaterials.get(material.name)) !== JSON.stringify(material.textures)),
    nineNamedChairs: JSON.stringify(candidate.report.chairs.map(chair => chair.name))
      === JSON.stringify(Array.from({length:9},(_,index)=>`chair_${index}`)),
    chair5CushionTargetDeltaMeters: candidate.report.chairs.find(chair=>chair.name==='chair_5')?.cushion?.centroid[1] - .574917,
    nonFinitePositionCount: candidate.report.nonFinitePositionCount,
    triangleCountChange: candidate.report.triangleCount - baseline.report.triangleCount,
    degenerateTriangleCountChange: candidate.report.degenerateTriangleCount - baseline.report.degenerateTriangleCount,
  };
}
const json = JSON.stringify(report, null, 2) + '\n';
if (option('--output')) await writeFile(resolve(option('--output')), json);
console.log(json);
