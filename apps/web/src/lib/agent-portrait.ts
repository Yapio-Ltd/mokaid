/** Only a dedicated head render belongs in a face slot, never a generation thumbnail. */
export function resolveAgentPortraitUrl(value?: string | null): string | null {
  if (!value) return null;
  const source = value.trim();
  try {
    const url = new URL(source);
    return url.protocol === "https:" && !url.username && !url.password ? source : null;
  } catch {
    return null;
  }
}
