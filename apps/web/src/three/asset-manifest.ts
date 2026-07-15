/**
 * Asset manifest for the 3D office.
 *
 * Environment loads from the hashed office GLB.
 * Characters resolve through the asset_3d catalog / CDN path (male + female).
 */

import { DEFAULT_AVATAR_CDN_PATH, resolveAgentGlbUrl } from "./agent-model";
import { OFFICE_ENVIRONMENT_CDN_PATH, resolveOfficeGlbUrl } from "./office-asset";

export interface AssetEntry {
  id: string;
  url: string;
  kind: "environment" | "furniture" | "avatar" | "prop";
}

export const ASSET_MANIFEST: Record<string, AssetEntry> = {
  office_environment: {
    id: "office_environment",
    url: resolveOfficeGlbUrl(),
    kind: "environment",
  },
  office_floor: { id: "office_floor", url: "procedural:floor", kind: "environment" },
  office_walls: { id: "office_walls", url: "procedural:walls", kind: "environment" },
  desk: { id: "desk", url: "procedural:desk", kind: "furniture" },
  chair: { id: "chair", url: "procedural:chair", kind: "furniture" },
  monitor: { id: "monitor", url: "procedural:monitor", kind: "furniture" },
  plant: { id: "plant", url: "procedural:plant", kind: "prop" },
  avatar_base: {
    id: "avatar_base",
    url: resolveAgentGlbUrl(DEFAULT_AVATAR_CDN_PATH),
    kind: "avatar",
  },
  avatar_female: {
    id: "avatar_female",
    url: resolveAgentGlbUrl("/assets3d/avatar_female.dbad3a7ec430.glb"),
    kind: "avatar",
  },
};

/** Convenience export for call sites that need the office path constant. */
export { OFFICE_ENVIRONMENT_CDN_PATH };

export function isProcedural(entry: AssetEntry): boolean {
  return entry.url.startsWith("procedural:");
}
