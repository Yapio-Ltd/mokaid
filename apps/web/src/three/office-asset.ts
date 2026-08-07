/**
 * Resolved URL for the hashed office environment GLB.
 * Local Vite serves /assets3d/*; production uses VITE_ASSETS_CDN_URL.
 *
 * Two variants after gltf-transform resize:
 * - desktop: textures capped at 2048 (≈17 MB, was 46 MB with 4K chair atlases)
 * - mobile:  textures capped at 1024 (≈5.6 MB) for tablet / phone GPU budgets
 */

import { resolveAgentGlbUrl } from "./agent-cdn";
import { detectOfficeDeviceProfile } from "./office-device-profile";

/** Hashed HQ office environment matching apps/web/public/assets3d. */
export const OFFICE_ENVIRONMENT_CDN_PATH = "/assets3d/office.25e579f05ec7.glb";

/** Lower-VRAM office variant for tablets and phones. */
export const OFFICE_ENVIRONMENT_MOBILE_CDN_PATH =
  "/assets3d/office.mobile.f132092042fa.glb";

export function resolveOfficeGlbUrl(): string {
  const profile = detectOfficeDeviceProfile();
  const path =
    profile.kind === "mobile"
      ? OFFICE_ENVIRONMENT_MOBILE_CDN_PATH
      : OFFICE_ENVIRONMENT_CDN_PATH;
  return resolveAgentGlbUrl(path);
}
