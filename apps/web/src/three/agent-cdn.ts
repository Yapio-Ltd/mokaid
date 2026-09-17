/**
 * CDN path helpers for agent GLBs — kept free of Babylon imports so UI
 * surfaces (avatars, catalogs) never pull the WebGL bundle into the entry.
 */

import { env } from "@/lib/env";

/** Hashed filename matching assets/optimized + S3 upload + asset_3d seed. */
export const DEFAULT_AVATAR_CDN_PATH = "/assets3d/avatar_male.21ca01757e1a.glb";

export function resolveAgentGlbUrl(cdnPath?: string | null): string {
  const path = (cdnPath && cdnPath.trim()) || DEFAULT_AVATAR_CDN_PATH;
  if (path.startsWith("http://") || path.startsWith("https://")) return path;
  const base = env.VITE_ASSETS_CDN_URL.trim().replace(/\/$/, "");
  if (!base) return path.startsWith("/") ? path : `/${path}`;
  return `${base}${path.startsWith("/") ? path : `/${path}`}`;
}

/** @deprecated Prefer resolveAgentGlbUrl() — kept for existing imports. */
export const AGENT_GLB_URL = resolveAgentGlbUrl();
