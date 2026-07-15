/**
 * Resolved URL for the hashed office environment GLB.
 * Local Vite serves /assets3d/*; production uses VITE_ASSETS_CDN_URL.
 */

import { resolveAgentGlbUrl } from "./agent-model";

/** Hashed HQ office environment matching apps/web/public/assets3d. */
export const OFFICE_ENVIRONMENT_CDN_PATH = "/assets3d/office.1fb918bd477b.glb";

export function resolveOfficeGlbUrl(): string {
  return resolveAgentGlbUrl(OFFICE_ENVIRONMENT_CDN_PATH);
}
