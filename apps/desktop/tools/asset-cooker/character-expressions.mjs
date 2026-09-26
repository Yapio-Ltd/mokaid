import {createHash} from 'node:crypto';

const VERSION = 'gentle-smile-1';
const freeze = value => {
  if (value && typeof value === 'object') {
    for (const child of Object.values(value)) freeze(child);
    Object.freeze(value);
  }
  return value;
};

/**
 * Anatomical landmarks in the shipped glTF's skinned bind-world metres, Y up,
 * face toward +Z. They were calibrated against orthographic albedo projections
 * and front-surface depth, not head bounds (hair and Legal's bun dominate those).
 * A corner entry is [half width, height, front depth]. Eye centres document the
 * protected region; cheeks stop below them. Existing open smiles retain teeth.
 */
export const characterExpressionProfiles = freeze({
  male: {mouth: [.027, 1.234, .127], cheeks: [.056, 1.272, .121], eyes: [.046, 1.325, .113],
    mouthRadius: [.035, .034, .033], cheekRadius: [.035, .027, .028], lift: .007, cheekLift: .0025, widen: .0014},
  design: {mouth: [.027, 1.254, .182], cheeks: [.060, 1.285, .171], eyes: [.045, 1.322, .167],
    mouthRadius: [.034, .029, .029], cheekRadius: [.035, .024, .027], lift: .0055, cheekLift: .0018, widen: .0011},
  finance: {mouth: [.023, 1.368, .110], cheeks: [.047, 1.392, .109], eyes: [.038, 1.422, .108],
    mouthRadius: [.029, .025, .024], cheekRadius: [.027, .018, .022], lift: .004, cheekLift: .0015, widen: .0007},
  corporate: {mouth: [.036, 1.574, .061], cheeks: [.055, 1.600, .060], eyes: [.038, 1.640, .065],
    mouthRadius: [.035, .029, .028], cheekRadius: [.030, .025, .025], lift: .0024, cheekLift: .001, widen: .0005},
  legal: {mouth: [.032, 1.239, .133], cheeks: [.063, 1.277, .133], eyes: [.062, 1.323, .117],
    mouthRadius: [.038, .034, .034], cheekRadius: [.039, .031, .030], lift: .009, cheekLift: .003, widen: .0015,
    innerBrows: [.027, 1.351, .151], browRadius: [.021, .017, .025], browLift: .0045},
  research: {mouth: [.067, 1.068, .021], cheeks: [.090, 1.099, .038], eyes: [.062, 1.174, .067],
    mouthRadius: [.051, .034, .045], cheekRadius: [.037, .029, .031], lift: .007, cheekLift: .002, widen: .001},
  developer: {mouth: [.032, 1.505, -.038], cheeks: [.051, 1.518, -.032], eyes: [.038, 1.560, -.031],
    mouthRadius: [.028, .022, .025], cheekRadius: [.025, .013, .020], lift: .0018, cheekLift: .0007, widen: .0003},
});

const families = freeze({
  avatar_male: 'male', avatar_design: 'design', avatar_female: 'design',
  avatar_finance: 'finance', avatar_nyx: 'finance',
  avatar_corporate: 'corporate', avatar_byte: 'corporate',
  avatar_legal: 'legal', avatar_research: 'research',
  avatar_developer: 'developer', avatar_moss: 'developer',
});

const smoothstep = (a, b, value) => {
  const t = Math.max(0, Math.min(1, (value - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

function kernel(point, center, radius) {
  const q = point.reduce((sum, value, axis) => sum + ((value - center[axis]) / radius[axis]) ** 2, 0);
  // Compact C2 support: hair, ears, eyeballs, nose and the rest of the body
  // remain bit-identical outside the calibrated mouth/cheek/brow neighbourhoods.
  return q < 1 ? (1 - q) ** 3 : 0;
}

/** Pure deformation field, useful for landmark and maximum-displacement tests. */
export function characterExpressionDelta(key, point) {
  const profile = characterExpressionProfiles[families[key]];
  if (!profile) return [0, 0, 0];
  const delta = [0, 0, 0];
  for (const side of [-1, 1]) {
    const mouth = [side * profile.mouth[0], ...profile.mouth.slice(1)];
    const cheek = [side * profile.cheeks[0], ...profile.cheeks.slice(1)];
    const pin = smoothstep(.10, .65, Math.abs(point[0]) / profile.mouth[0]);
    const smile = kernel(point, mouth, profile.mouthRadius) * pin;
    const cheekWeight = kernel(point, cheek, profile.cheekRadius);
    delta[0] += side * profile.widen * smile;
    delta[1] += profile.lift * smile + profile.cheekLift * cheekWeight;
    if (profile.innerBrows) {
      const brow = [side * profile.innerBrows[0], ...profile.innerBrows.slice(1)];
      delta[1] += profile.browLift * kernel(point, brow, profile.browRadius);
    }
  }
  return delta;
}

function multiply(a, b) {
  const result = Array(16).fill(0);
  for (let column = 0; column < 4; column++)
    for (let row = 0; row < 4; row++)
      for (let axis = 0; axis < 4; axis++)
        result[column * 4 + row] += a[axis * 4 + row] * b[column * 4 + axis];
  return result;
}
function transformed(matrix, point) {
  return [0, 1, 2].map(row => matrix[row] * point[0] + matrix[row + 4] * point[1] +
    matrix[row + 8] * point[2] + matrix[row + 12]);
}
function inverseVector(matrix, vector) {
  const a = matrix[0], b = matrix[4], c = matrix[8], d = matrix[1], e = matrix[5],
    f = matrix[9], g = matrix[2], h = matrix[6], i = matrix[10];
  const determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (Math.abs(determinant) < 1e-10) throw Error('Character expression encountered a singular bind transform');
  const [x, y, z] = vector;
  return [((e * i - f * h) * x + (c * h - b * i) * y + (b * f - c * e) * z) / determinant,
    ((f * g - d * i) * x + (a * i - c * g) * y + (c * d - a * f) * z) / determinant,
    ((d * h - e * g) * x + (b * g - a * h) * y + (a * e - b * d) * z) / determinant];
}

/**
 * Bake a gentle smile into a known bundled character, leaving UVs, materials,
 * topology, skin weights, node transforms and all 48 animation tracks unchanged.
 * The caller must run prepareCharacterNormals(document) after this function.
 * Imported mesh nodes can carry 0.01 scale while their skin palette cancels it;
 * using joint-world × inverse-bind (not mesh-world) is essential here.
 * Unknown/custom avatars are deliberately untouched rather than guessed.
 */
export function applyCharacterExpression(document, key) {
  const family = families[key];
  if (!family) return {profile: null, correctedVertices: 0, skipped: true};
  const profile = characterExpressionProfiles[family];
  const profileHash = createHash('sha256').update(JSON.stringify({version: VERSION, family, profile})).digest('hex');
  const entries = [];
  const eligible = new Set();
  const seen = new Set();
  const sourceBounds = profile.innerBrows ? profile.innerBrows[1] + profile.browRadius[1] :
    profile.cheeks[1] + profile.cheekRadius[1];
  const lowerBound = profile.mouth[1] - profile.mouthRadius[1];
  for (const node of document.getRoot().listNodes()) {
    const mesh = node.getMesh(), skin = node.getSkin();
    if (!mesh || !skin || /^Office(?:Coffee|Phone)/.test(node.getName())) continue;
    const joints = skin.listJoints();
    const head = joints.findIndex(joint => /(?:^|[|/:])head(?:\.x)?$/i.test(joint.getName()));
    if (head < 0) continue;
    const inverseBind = skin.getInverseBindMatrices();
    if (!inverseBind) throw Error(`${key}: facial calibration requires explicit inverse-bind matrices`);
    const palette = joints.map((joint, index) => multiply(joint.getWorldMatrix(), inverseBind.getElement(index, [])));
    for (const primitive of mesh.listPrimitives()) {
      if (seen.has(primitive)) throw Error(`${key}: shared facial mesh instances require explicit calibration`);
      seen.add(primitive);
      const positions = primitive.getAttribute('POSITION');
      const boneIds = primitive.getAttribute('JOINTS_0'), weights = primitive.getAttribute('WEIGHTS_0');
      if (!positions || !boneIds || !weights) continue;
      const candidates = [];
      for (let index = 0; index < positions.getCount(); index++) {
        const position = positions.getElement(index, []);
        const ids = boneIds.getElement(index, []), influence = weights.getElement(index, []);
        const matrix = Array(16).fill(0);
        let headWeight = 0;
        for (let slot = 0; slot < ids.length; slot++) {
          if (!influence[slot]) continue;
          if (ids[slot] === head) headWeight += influence[slot];
          const bone = palette[ids[slot]];
          if (!bone) throw Error(`${key}: invalid facial skin joint`);
          for (let element = 0; element < 16; element++) matrix[element] += bone[element] * influence[slot];
        }
        const world = transformed(matrix, position);
        if (world[1] < lowerBound || world[1] > sourceBounds) continue;
        const delta = characterExpressionDelta(key, world);
        if (Math.hypot(...delta) < 1e-9) continue;
        const seamKey = world.map(value => Math.round(value * 100000)).join(',');
        if (headWeight > .35) eligible.add(seamKey);
        candidates.push({index, matrix, delta, seamKey, position});
      }
      if (candidates.length) entries.push({primitive, positions, candidates});
    }
  }
  let correctedVertices = 0, correctedPrimitives = 0, maximumDisplacement = 0;
  for (const {primitive, positions, candidates} of entries) {
    const array = new Float32Array(positions.getArray());
    let count = 0;
    for (const {index, matrix, delta, seamKey, position} of candidates) {
      if (!eligible.has(seamKey)) continue;
      const local = inverseVector(matrix, delta);
      for (let axis = 0; axis < 3; axis++) array[index * 3 + axis] = position[axis] + local[axis];
      maximumDisplacement = Math.max(maximumDisplacement, Math.hypot(...delta));
      count++;
    }
    if (!count) continue;
    // A distinct accessor avoids changing a shared original buffer through a
    // primitive whose bind transform may differ. UV-seam copies see one field.
    primitive.setAttribute('POSITION', positions.clone().setArray(array));
    correctedVertices += count;
    correctedPrimitives++;
  }
  if (!correctedVertices) throw Error(`${key}: calibrated smile did not reach any facial vertices`);
  return {profile: family, version: VERSION, profileHash, correctedVertices,
    correctedPrimitives, maximumDisplacement, normalsRequireUpdate: true};
}
