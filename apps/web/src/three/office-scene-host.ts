/**
 * Persistent host for the Babylon office: one WebGL context + canvas survive
 * React route changes. Pause on leave, resume on re-enter — no GLB reload.
 * Full dispose only on logout / workspace switch / build bump.
 */

import { OFFICE_SCENE_BUILD, OfficeScene } from "./office-scene";
import type { SceneAgent, SceneCallbacks } from "./types";

/**
 * Bump when collision/socket logic changes so the singleton is recreated.
 * Defined in office-scene so the debug snapshot reports the same number
 * (importing it back from here would close an import cycle).
 */
export { OFFICE_SCENE_BUILD };

interface HostState {
  canvas: HTMLCanvasElement;
  scene: OfficeScene;
  workspaceId: string;
  build: number;
}

let host: HostState | null = null;

function createCanvas(): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.className = "h-full w-full outline-none";
  canvas.setAttribute("aria-label", "3D office view");
  canvas.style.display = "block";
  canvas.style.width = "100%";
  canvas.style.height = "100%";
  return canvas;
}

/**
 * Attach the singleton canvas into `container` and return the live scene.
 * Reuses the existing WebGL context when remounting the same workspace.
 */
export function attachOfficeHost(
  container: HTMLElement,
  workspaceId: string,
  callbacks: SceneCallbacks,
): OfficeScene {
  if (host && (host.workspaceId !== workspaceId || host.build !== OFFICE_SCENE_BUILD)) {
    disposeOfficeHost();
  }

  if (!host) {
    const canvas = createCanvas();
    container.appendChild(canvas);
    const scene = new OfficeScene(canvas, callbacks);
    host = { canvas, scene, workspaceId, build: OFFICE_SCENE_BUILD };
    return scene;
  }

  if (host.canvas.parentElement !== container) {
    container.appendChild(host.canvas);
  }
  host.scene.setCallbacks(callbacks);
  host.scene.resume();
  return host.scene;
}

/** Pause rendering and detach the canvas without destroying WebGL. */
export function detachOfficeHost(container?: HTMLElement | null) {
  if (!host) return;
  host.scene.pause();
  const parent = host.canvas.parentElement;
  if (parent && (!container || parent === container)) {
    parent.removeChild(host.canvas);
  }
}

/** Tear down WebGL + canvas (logout or workspace change). */
export function disposeOfficeHost() {
  if (!host) return;
  host.scene.dispose();
  host.canvas.remove();
  host = null;
}

export function getOfficeHostScene(): OfficeScene | null {
  return host?.scene ?? null;
}

export function updateOfficeHostAgents(agents: SceneAgent[]) {
  host?.scene.updateAgents(agents);
}

/** Expose loco debug on window for Playwright / console checks. */
export function bindOfficeDebugGlobal() {
  if (typeof window === "undefined") return;
  (window as unknown as { __mokaidOfficeDebug?: () => unknown }).__mokaidOfficeDebug = () =>
    host?.scene.debugLocoSnapshot() ?? { officeReady: false, crowdReady: false, agents: [] };
  // Raw office-GLB point → canvas pixels, so a verification script can check
  // that what the data says lines up with what the camera actually shows.
  (
    window as unknown as { __mokaidOfficeProject?: (x: number, z: number, y?: number) => unknown }
  ).__mokaidOfficeProject = (x, z, y) => host?.scene.debugProject(x, z, y) ?? null;
  // Plant a visible pillar at a raw coordinate to check nav data against the render.
  (
    window as unknown as { __mokaidOfficeMark?: (x: number, z: number, hex?: string) => void }
  ).__mokaidOfficeMark = (x, z, hex) => host?.scene.debugMarker(x, z, hex);
}

bindOfficeDebugGlobal();

// Hot reload: drop the singleton so the next attach gets fresh collision/socket code.
// React re-attaches when OFFICE_SCENE_BUILD bumps; office-canvas also re-pushes agents
// on attach + officeReady so HMR never leaves an empty avatars map.
if (import.meta.hot) {
  import.meta.hot.accept(() => {
    disposeOfficeHost();
  });
  import.meta.hot.accept("./office-scene", () => {
    disposeOfficeHost();
  });
  import.meta.hot.accept("./office-collisions", () => {
    disposeOfficeHost();
  });
  import.meta.hot.accept("./office-navdata", () => {
    disposeOfficeHost();
  });
  import.meta.hot.accept("./office-crowd", () => {
    disposeOfficeHost();
  });
  import.meta.hot.accept("./office-lighting", () => {
    disposeOfficeHost();
  });
}
