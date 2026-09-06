/**
 * Always-mounted park — sole parent of the office WebGL canvas.
 * Lives outside AppShell's routeKey remount. Never uses visibility:hidden
 * or display:none (Chrome evicts the WebGL context). Off-dashboard the
 * park sits at left:-10000px with the same size; on-dashboard the host
 * copies the slot's getBoundingClientRect onto this element.
 */

import { useLayoutEffect, useRef } from "react";
import { useWorkspace } from "@/api/hooks";
import { env } from "@/lib/env";
import { useAuthStore } from "@/stores/auth-store";
import { ensureOfficeHost, setOfficePark } from "./office-scene-host";

const PARK_HEIGHT = 560;

export function OfficePark() {
  const parkRef = useRef<HTMLDivElement>(null);
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const { data: workspaceData } = useWorkspace();
  const enabled =
    Boolean(workspaceId) &&
    !env.VITE_DISABLE_3D &&
    workspaceData?.data.feature_toggles?.["3d_office"] !== false;

  useLayoutEffect(() => {
    setOfficePark(parkRef.current);
    return () => setOfficePark(null);
  }, []);

  useLayoutEffect(() => {
    if (!enabled || !workspaceId || !parkRef.current) return;
    setOfficePark(parkRef.current);
    ensureOfficeHost(workspaceId);
  }, [enabled, workspaceId]);

  return (
    <div
      ref={parkRef}
      aria-hidden
      className="pointer-events-none"
      style={{
        position: "fixed",
        left: -10000,
        top: 0,
        width: "100vw",
        height: PARK_HEIGHT,
        zIndex: -1,
      }}
    />
  );
}
