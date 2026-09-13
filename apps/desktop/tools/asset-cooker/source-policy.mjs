export const avatarKeys = Object.freeze([
  'avatar_male', 'avatar_design', 'avatar_finance', 'avatar_corporate',
  'avatar_legal', 'avatar_research', 'avatar_developer',
]);

export function parseAvatarCatalog(text) {
  const pattern = /"slug"\s*=>\s*"(avatar_[a-z]+)"[\s\S]*?"cdn_path"\s*=>\s*"([^"]+)"[\s\S]*?"sha256"\s*=>\s*"([0-9a-f]{64})"/g;
  const matches = [...text.matchAll(pattern)];
  const catalog = new Map(matches.map(match => [
    match[1], { path: match[2], sha256: match[3] },
  ]));
  if (catalog.size !== avatarKeys.length || matches.length !== catalog.size)
    throw Error('Avatar catalog changed: review desktop source mapping');
  for (const key of avatarKeys) {
    const entry = catalog.get(key);
    if (!entry || entry.path !== `/assets3d/${key}.${entry.sha256.slice(0, 12)}.glb`)
      throw Error(`Invalid content-addressed avatar catalog entry: ${key}`);
  }
  return catalog;
}

export function catalogEntry(catalog, key) {
  // Backend metadata defines female as the design avatar's legacy slug.
  const entry = catalog.get(key === 'avatar_female' ? 'avatar_design' : key);
  if (!entry) throw Error(`Missing catalog asset ${key}`);
  return entry;
}

export function validateAnimationValues(inputCount, values, label) {
  if (!inputCount || !values.getCount()) throw Error(`${label}: empty animation`);
  if (inputCount === values.getCount()) return;
  // Legacy desk patching reused another channel's length for constant legs.
  // Reconcile only constants; a varying curve needs explicit source repair.
  const first = values.getElement(0, []);
  for (let index = 1; index < values.getCount(); ++index) {
    if (values.getElement(index, []).some((value, axis) =>
      Math.abs(value - first[axis]) > 1e-7))
      throw Error(`${label}: nonconstant animation input/output count mismatch`);
  }
}
