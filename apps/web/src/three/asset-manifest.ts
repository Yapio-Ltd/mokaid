/**
 * Asset manifest for the 3D office.
 *
 * Production GLB/KTX2 assets are not delivered yet: every entry currently
 * points to `procedural:*`, which the AssetManager resolves to runtime-built
 * placeholder meshes. When final assets arrive, swap the URLs for CDN paths
 * (e.g. `${VITE_ASSETS_CDN_URL}/office/desk.glb`) with no scene code changes.
 */

export interface AssetEntry {
  id: string;
  url: string;
  kind: "environment" | "furniture" | "avatar" | "prop";
}

export const ASSET_MANIFEST: Record<string, AssetEntry> = {
  office_floor: { id: "office_floor", url: "procedural:floor", kind: "environment" },
  office_walls: { id: "office_walls", url: "procedural:walls", kind: "environment" },
  desk: { id: "desk", url: "procedural:desk", kind: "furniture" },
  chair: { id: "chair", url: "procedural:chair", kind: "furniture" },
  monitor: { id: "monitor", url: "procedural:monitor", kind: "furniture" },
  plant: { id: "plant", url: "procedural:plant", kind: "prop" },
  avatar_base: { id: "avatar_base", url: "procedural:avatar", kind: "avatar" },
};

export function isProcedural(entry: AssetEntry): boolean {
  return entry.url.startsWith("procedural:");
}
