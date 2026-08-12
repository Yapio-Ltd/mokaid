/**
 * Resolved URL for the hashed office environment GLB.
 * Local Vite serves /assets3d/*; production uses VITE_ASSETS_CDN_URL.
 *
 * Two variants after gltf-transform resize + dequantize + instance expand:
 * - desktop: textures capped at 2048, float32 attrs (≈19 MB)
 * - mobile:  textures capped at 1024, float32 attrs (≈7 MB)
 *
 * Never ship KHR_mesh_quantization on these — SHORT positions explode on
 * Windows Chrome/ANGLE. See scripts/optimize-assets.sh.
 */

import { resolveAgentGlbUrl } from "./agent-cdn";
import { detectOfficeDeviceProfile } from "./office-device-profile";

/** Hashed HQ office environment matching apps/web/public/assets3d. */
export const OFFICE_ENVIRONMENT_CDN_PATH = "/assets3d/office.a830ba995121.glb";

/** Lower-VRAM office variant for tablets and phones. */
export const OFFICE_ENVIRONMENT_MOBILE_CDN_PATH =
  "/assets3d/office.mobile.b016323b07bd.glb";

export function resolveOfficeGlbUrl(): string {
  const profile = detectOfficeDeviceProfile();
  const path =
    profile.kind === "mobile"
      ? OFFICE_ENVIRONMENT_MOBILE_CDN_PATH
      : OFFICE_ENVIRONMENT_CDN_PATH;
  return resolveAgentGlbUrl(path);
}
