/** Explicit renderer semantics, independent of mesh ordering and atlas colors. */
export function surfaceKind(name, office = false) {
  const normalized = name.trim();
  if (office && /^Desktop screen(?: \d+)?$/.test(normalized)) return 1;
  if (normalized === 'Desktop phone' || normalized === 'Desktop phone screen') return 2;
  if (normalized === 'Desktop phone dock') return 3;
  return 0;
}
