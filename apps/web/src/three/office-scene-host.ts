/**
 * Persistent host for the Babylon office: one WebGL context + canvas survive
 * React route changes. Pause on leave, resume on re-enter — no GLB reload.
 * Full dispose only on logout / workspace switch / build bump.
 *
 * Context loss (Chrome tab eviction, Windows GPU TDR) rebuilds a fresh canvas
 * instead of locking the dashboard on the 2D fallback.
 */

import { OFFICE_SCENE_BUILD, OfficeScene } from "./office-scene";
import { nextRecoveryStep, resetRecoveryState, shouldRebuildOnAttach } from "./office-recovery";
import type { SceneAgent, SceneCallbacks } from "./types";

/**
 * Bump when collision/socket logic changes so the singleton is recreated.
 * Defined in office-scene so the debug snapshot reports the same number
 * (importing it back from here would close an import cycle).
 */
export { OFFICE_SCENE_BUILD };

export type HostStatus = "running" | "lost" | "restoring" | "failed";

interface HostState {
  canvas: HTMLCanvasElement;
  scene: OfficeScene;
  workspaceId: string;
  build: number;
}

const RESTORE_WAIT_MS = 1_500;
/** A scene that stayed ready this long was healthy — next loss is tab eviction. */
const HEALTHY_SCENE_MS = 10_000;

let host: HostState | null = null;
let status: HostStatus = "running";
const listeners = new Set<(s: HostStatus) => void>();

let lastContainer: HTMLElement | null = null;
let lastWorkspaceId: string | null = null;
let lastCallbacks: SceneCallbacks | null = null;
let lastAgents: SceneAgent[] = [];
/** Always-mounted park — sole parent of the canvas for the whole session. */
let parkEl: HTMLElement | null = null;
let officeSlot: HTMLElement | null = null;
let overlayEl: HTMLElement | null = null;
let slotObserver: ResizeObserver | null = null;
let slotLayoutBound = false;
const overlayListeners = new Set<(el: HTMLElement | null) => void>();
const PARK_OFFSCREEN_LEFT = "-10000px";
const PARK_HEIGHT_PX = 560;

let recoveryAttempts = 0;
let firstFailureAt: number | null = null;
let lastReadyAt = 0;
let restoreTimer: ReturnType<typeof setTimeout> | null = null;
let rebuildInFlight = false;
let visibilityBound = false;

export function getOfficeHostStatus(): HostStatus {
  return status;
}

export function getOfficeRecoveryAttempts(): number {
  return recoveryAttempts;
}

export function subscribeOfficeHostStatus(listener: (s: HostStatus) => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

function setStatus(next: HostStatus) {
  if (status === next) return;
  status = next;
  for (const listener of listeners) listener(next);
}

function bindVisibilityListener() {
  if (visibilityBound || typeof document === "undefined") return;
  visibilityBound = true;
  document.addEventListener("visibilitychange", onDocumentVisibility);
}

function onDocumentVisibility() {
  if (typeof document === "undefined" || document.hidden) return;
  if (status === "lost") {
    scheduleRebuild("visible");
  }
}

function clearRestoreTimer() {
  if (restoreTimer == null) return;
  clearTimeout(restoreTimer);
  restoreTimer = null;
}

function bindHostCallbacks(callbacks: SceneCallbacks): SceneCallbacks {
  return {
    ...callbacks,
    onOfficeReady: (ok) => {
      if (ok) lastReadyAt = performance.now();
      callbacks.onOfficeReady?.(ok);
    },
    onContextLost: () => {
      callbacks.onContextLost?.();
      handleOfficeContextLost();
    },
    onContextRestored: () => {
      callbacks.onContextRestored?.();
      handleOfficeContextRestored();
    },
  };
}

function createCanvas(): HTMLCanvasElement {
  const canvas = document.createElement("canvas");
  canvas.className = "h-full w-full outline-none";
  canvas.setAttribute("aria-label", "3D office view");
  canvas.style.display = "block";
  canvas.style.width = "100%";
  canvas.style.height = "100%";
  return canvas;
}

function teardownHost() {
  if (!host) return;
  try {
    host.scene.dispose();
  } catch {
    /* engine may already be dead after context loss */
  }
  host.canvas.remove();
  host = null;
}

function notifyOverlayListeners() {
  for (const listener of overlayListeners) listener(overlayEl);
}

function ensureOverlay(park: HTMLElement): HTMLElement {
  let overlay = park.querySelector("[data-office-overlay]") as HTMLElement | null;
  if (!overlay) {
    overlay = document.createElement("div");
    overlay.dataset.officeOverlay = "";
    overlay.style.position = "absolute";
    overlay.style.inset = "0";
    overlay.style.zIndex = "10";
    overlay.style.pointerEvents = "none";
    park.appendChild(overlay);
  }
  if (overlayEl !== overlay) {
    overlayEl = overlay;
    notifyOverlayListeners();
  }
  return overlay;
}

function attachCanvasToPark(park: HTMLElement, canvas: HTMLCanvasElement) {
  const overlay = ensureOverlay(park);
  if (canvas.parentElement === park) return;
  park.insertBefore(canvas, overlay);
}

function ensureParkElement(): HTMLElement {
  if (parkEl) return parkEl;
  const el = document.createElement("div");
  el.dataset.officePark = "fallback";
  el.setAttribute("aria-hidden", "true");
  applyParkOffscreen(el);
  document.body.appendChild(el);
  parkEl = el;
  ensureOverlay(el);
  return el;
}

function applyParkOffscreen(el: HTMLElement) {
  el.style.position = "fixed";
  el.style.left = PARK_OFFSCREEN_LEFT;
  el.style.top = "0";
  el.style.width = "100vw";
  el.style.height = `${PARK_HEIGHT_PX}px`;
  el.style.pointerEvents = "none";
  el.style.zIndex = "-1";
  el.style.visibility = "visible";
  el.style.overflow = "hidden";
  el.setAttribute("aria-hidden", "true");
}

function applyParkLayout() {
  if (!parkEl) return;
  if (officeSlot) {
    const r = officeSlot.getBoundingClientRect();
    const w = Math.max(1, r.width);
    const h = Math.max(1, r.height);
    parkEl.style.position = "fixed";
    parkEl.style.left = `${r.left}px`;
    parkEl.style.top = `${r.top}px`;
    parkEl.style.width = `${w}px`;
    parkEl.style.height = `${h}px`;
    parkEl.style.visibility = "visible";
    parkEl.style.pointerEvents = "auto";
    parkEl.style.zIndex = "2";
    parkEl.style.overflow = "hidden";
    parkEl.removeAttribute("aria-hidden");
    return;
  }
  applyParkOffscreen(parkEl);
}

function bindSlotLayout() {
  unbindSlotLayout();
  if (!officeSlot || typeof window === "undefined") return;
  slotLayoutBound = true;
  slotObserver = new ResizeObserver(() => applyParkLayout());
  slotObserver.observe(officeSlot);
  window.addEventListener("scroll", applyParkLayout, true);
  window.addEventListener("resize", applyParkLayout);
  applyParkLayout();
}

function unbindSlotLayout() {
  if (!slotLayoutBound) return;
  slotLayoutBound = false;
  slotObserver?.disconnect();
  slotObserver = null;
  if (typeof window !== "undefined") {
    window.removeEventListener("scroll", applyParkLayout, true);
    window.removeEventListener("resize", applyParkLayout);
  }
}

function createFreshHost(useSafeProfile: boolean, recoveryAttempt: number): OfficeScene {
  const home = ensureParkElement();
  if (!lastWorkspaceId || !lastCallbacks) {
    throw new Error("Office host has no container to rebuild into");
  }
  teardownHost();
  const canvas = createCanvas();
  attachCanvasToPark(home, canvas);
  const scene = new OfficeScene(canvas, bindHostCallbacks(lastCallbacks), {
    useSafeProfile,
    recoveryAttempt,
  });
  host = { canvas, scene, workspaceId: lastWorkspaceId, build: OFFICE_SCENE_BUILD };
  if (lastAgents.length) scene.updateAgents(lastAgents);
  return scene;
}

function rememberAttach(container: HTMLElement, workspaceId: string, callbacks: SceneCallbacks) {
  lastContainer = container;
  lastWorkspaceId = workspaceId;
  lastCallbacks = callbacks;
  bindVisibilityListener();
}

function scheduleRebuild(reason: string) {
  if (typeof document !== "undefined" && document.hidden) {
    setStatus("lost");
    return;
  }
  clearRestoreTimer();
  restoreTimer = setTimeout(() => {
    restoreTimer = null;
    rebuildHost(reason);
  }, RESTORE_WAIT_MS);
}

function rebuildHost(reason: string): OfficeScene | null {
  if (rebuildInFlight) return host?.scene ?? null;
  rebuildInFlight = true;
  try {
    const now = Date.now();
    const step = nextRecoveryStep(recoveryAttempts, firstFailureAt, now);
    if (step.kind === "failed") {
      console.warn("[3d] recovery exhausted — 2D fallback", reason);
      setStatus("failed");
      teardownHost();
      return null;
    }
    recoveryAttempts = step.attempt;
    if (firstFailureAt == null) firstFailureAt = now;

    if (typeof document !== "undefined" && document.hidden) {
      setStatus("lost");
      return null;
    }

    setStatus("restoring");
    console.info(
      `[3d] rebuilding WebGL (${reason}) attempt=${step.attempt} safe=${step.useSafeProfile}`,
    );
    const scene = createFreshHost(step.useSafeProfile, step.attempt);
    setStatus("running");
    return scene;
  } catch (err) {
    console.warn("[3d] rebuild failed", reason, err);
    const retry = nextRecoveryStep(recoveryAttempts, firstFailureAt, Date.now());
    if (retry.kind === "failed") {
      setStatus("failed");
      teardownHost();
      return null;
    }
    recoveryAttempts = retry.attempt;
    if (firstFailureAt == null) firstFailureAt = Date.now();
    try {
      const scene = createFreshHost(retry.useSafeProfile, retry.attempt);
      setStatus("running");
      return scene;
    } catch (retryErr) {
      console.warn("[3d] safe rebuild failed", retryErr);
      setStatus("failed");
      teardownHost();
      return null;
    }
  } finally {
    rebuildInFlight = false;
  }
}

/**
 * Tab eviction after a healthy scene is not a failure: rebuild with the
 * same profile and do not burn a recovery attempt.
 */
function rebuildHealthyLoss(reason: string): OfficeScene | null {
  if (rebuildInFlight) return host?.scene ?? null;
  rebuildInFlight = true;
  try {
    if (typeof document !== "undefined" && document.hidden) {
      setStatus("lost");
      return null;
    }
    setStatus("restoring");
    console.info(`[3d] rebuilding WebGL after healthy loss (${reason})`);
    const scene = createFreshHost(false, 0);
    setStatus("running");
    return scene;
  } catch (err) {
    console.warn("[3d] healthy-loss rebuild failed", err);
    rebuildInFlight = false;
    return rebuildHost(reason);
  } finally {
    rebuildInFlight = false;
  }
}

export function handleOfficeContextLost() {
  if (status === "failed" || status === "restoring") return;
  host?.scene.pause();
  setStatus("lost");

  const healthy = lastReadyAt > 0 && performance.now() - lastReadyAt >= HEALTHY_SCENE_MS;
  const start = () => {
    if (healthy) rebuildHealthyLoss("contextlost");
    else rebuildHost("contextlost");
  };

  if (typeof document !== "undefined" && document.hidden) {
    return;
  }
  clearRestoreTimer();
  restoreTimer = setTimeout(() => {
    restoreTimer = null;
    start();
  }, RESTORE_WAIT_MS);
}

export function handleOfficeContextRestored() {
  if (status !== "lost") return;
  clearRestoreTimer();
  if (typeof document !== "undefined" && document.hidden) return;
  const healthy = lastReadyAt > 0 && performance.now() - lastReadyAt >= HEALTHY_SCENE_MS;
  if (healthy) rebuildHealthyLoss("contextrestored");
  else rebuildHost("contextrestored");
}

export function resetOfficeRecovery() {
  const cleared = resetRecoveryState();
  recoveryAttempts = cleared.attempts;
  firstFailureAt = cleared.firstFailureAt;
  lastReadyAt = 0;
  clearRestoreTimer();
  setStatus("running");
}

export function setOfficePark(el: HTMLElement | null) {
  if (!el) {
    if (parkEl?.dataset.officePark === "fallback") return;
    parkEl = null;
    if (host && typeof document !== "undefined") {
      const fallback = ensureParkElement();
      attachCanvasToPark(fallback, host.canvas);
      applyParkLayout();
    }
    return;
  }
  if (parkEl && parkEl !== el) {
    if (host && host.canvas.parentElement === parkEl) {
      attachCanvasToPark(el, host.canvas);
    }
    if (parkEl.dataset.officePark === "fallback") parkEl.remove();
  }
  parkEl = el;
  ensureOverlay(el);
  if (host && host.canvas.parentElement !== el) {
    attachCanvasToPark(el, host.canvas);
  }
  applyParkLayout();
}

export function setOfficeOverlayEl(el: HTMLElement | null) {
  overlayEl = el;
  notifyOverlayListeners();
}

export function getOfficeParkEl(): HTMLElement | null {
  return parkEl;
}

export function getOfficeOverlayEl(): HTMLElement | null {
  return overlayEl;
}

export function subscribeOfficeOverlayEl(listener: (el: HTMLElement | null) => void): () => void {
  overlayListeners.add(listener);
  return () => {
    overlayListeners.delete(listener);
  };
}

const NOOP_CALLBACKS: SceneCallbacks = {
  onSelectAgent: () => undefined,
  onFps: () => undefined,
  onBubblePositions: () => undefined,
};

/**
 * Create the scene on the park if it does not exist yet. Stays paused until
 * a dashboard slot calls attachOfficeHost / setOfficeSlot.
 */
export function ensureOfficeHost(workspaceId: string, callbacks?: SceneCallbacks): OfficeScene | null {
  const home = parkEl ?? (typeof document !== "undefined" ? ensureParkElement() : null);
  if (!home) return host?.scene ?? null;
  rememberAttach(home, workspaceId, callbacks ?? lastCallbacks ?? NOOP_CALLBACKS);
  if (host && (host.workspaceId !== workspaceId || host.build !== OFFICE_SCENE_BUILD)) {
    teardownHost();
  }
  if (host) {
    if (officeSlot) host.scene.resume();
    return host.scene;
  }
  try {
    const canvas = createCanvas();
    attachCanvasToPark(home, canvas);
    const scene = new OfficeScene(canvas, bindHostCallbacks(lastCallbacks ?? NOOP_CALLBACKS), {
      useSafeProfile: false,
      recoveryAttempt: 0,
    });
    host = { canvas, scene, workspaceId, build: OFFICE_SCENE_BUILD };
    if (lastAgents.length) scene.updateAgents(lastAgents);
    if (officeSlot) scene.resume();
    else scene.pause();
    setStatus("running");
    return scene;
  } catch (err) {
    console.warn("[3d] WebGL initialization failed", err);
    return rebuildHost("ensure-throw");
  }
}

/** Pause the render loop and slide the park off-screen. Canvas stays parented. */
export function parkOfficeHost() {
  officeSlot = null;
  unbindSlotLayout();
  host?.scene.pause();
  applyParkLayout();
}

/** @deprecated use parkOfficeHost */
export function detachOfficeHost(_container?: HTMLElement | null) {
  parkOfficeHost();
}

export function setOfficeSlot(el: HTMLElement | null) {
  lastContainer = el ?? lastContainer;
  officeSlot = el;
  if (el) {
    bindSlotLayout();
    host?.scene.resume();
    return;
  }
  parkOfficeHost();
}

/**
 * Create the singleton on the park (or `container`) if needed.
 * Reuses the existing WebGL context — navigation must not rebuild.
 */
export function attachOfficeHost(
  container: HTMLElement,
  workspaceId: string,
  callbacks: SceneCallbacks,
): OfficeScene {
  rememberAttach(container, workspaceId, callbacks);

  if (host && (host.workspaceId !== workspaceId || host.build !== OFFICE_SCENE_BUILD)) {
    teardownHost();
  }

  const lost = Boolean(host?.scene.isContextLost());
  const hasParent = Boolean(host?.canvas.parentElement);
  if (host && shouldRebuildOnAttach({ canvasHasParent: hasParent, contextLost: lost })) {
    const rebuilt = handleLostOnAttach();
    if (rebuilt) {
      setOfficeSlot(container);
      return rebuilt;
    }
    throw new Error("WebGL context lost");
  }

  if (!host) {
    try {
      const home = ensureParkElement();
      const canvas = createCanvas();
      attachCanvasToPark(home, canvas);
      const scene = new OfficeScene(canvas, bindHostCallbacks(callbacks), {
        useSafeProfile: false,
        recoveryAttempt: 0,
      });
      host = { canvas, scene, workspaceId, build: OFFICE_SCENE_BUILD };
      if (lastAgents.length) scene.updateAgents(lastAgents);
      setStatus("running");
      setOfficeSlot(container);
      return scene;
    } catch (err) {
      console.warn("[3d] WebGL initialization failed", err);
      const rebuilt = rebuildHost("attach-throw");
      if (rebuilt) {
        setOfficeSlot(container);
        return rebuilt;
      }
      throw err;
    }
  }

  host.scene.setCallbacks(bindHostCallbacks(callbacks));
  setStatus("running");
  setOfficeSlot(container);
  return host.scene;
}

function handleLostOnAttach(): OfficeScene | null {
  const healthy = lastReadyAt > 0 && performance.now() - lastReadyAt >= HEALTHY_SCENE_MS;
  if (healthy) return rebuildHealthyLoss("attach-lost");
  return rebuildHost("attach-lost");
}

/** Tear down WebGL + canvas (logout or workspace change). */
export function disposeOfficeHost() {
  clearRestoreTimer();
  unbindSlotLayout();
  officeSlot = null;
  teardownHost();
  lastAgents = [];
  lastCallbacks = null;
  lastContainer = null;
  lastWorkspaceId = null;
  resetOfficeRecovery();
}

export function getOfficeHostScene(): OfficeScene | null {
  return host?.scene ?? null;
}

export function updateOfficeHostAgents(agents: SceneAgent[]) {
  lastAgents = agents;
  host?.scene.updateAgents(agents);
}

/** Expose loco debug on window for Playwright / console checks. */
export function bindOfficeDebugGlobal() {
  if (typeof window === "undefined") return;
  (window as unknown as { __mokaidOfficeDebug?: () => unknown }).__mokaidOfficeDebug = () => ({
    ...(host?.scene.debugLocoSnapshot() ?? { officeReady: false, crowdReady: false, agents: [] }),
    hostStatus: status,
    recoveryAttempts,
  });
  // Raw office-GLB point → canvas pixels, so a verification script can check
  // that what the data says lines up with what the camera actually shows.
  (
    window as unknown as { __mokaidOfficeProject?: (x: number, z: number, y?: number) => unknown }
  ).__mokaidOfficeProject = (x, z, y) => host?.scene.debugProject(x, z, y) ?? null;
  // Plant a visible pillar at a raw coordinate to check nav data against the render.
  (
    window as unknown as { __mokaidOfficeMark?: (x: number, z: number, hex?: string) => void }
  ).__mokaidOfficeMark = (x, z, hex) => host?.scene.debugMarker(x, z, hex);

  (
    window as unknown as { __mokaidOfficeMats?: () => unknown }
  ).__mokaidOfficeMats = () => {
    if (!host) return null;
    // OfficeScene private `scene` accessed for diagnostics only.
    const babylonScene = (host.scene as unknown as { scene: import("@babylonjs/core").Scene }).scene;
    if (!babylonScene) return { err: "no babylon scene" };
    const out: Array<Record<string, unknown>> = [];
    for (const m of babylonScene.materials) {
      const pm = m as {
        name?: string;
        emissiveIntensity?: number;
        emissiveColor?: { r: number; g: number; b: number };
        albedoColor?: { r: number; g: number; b: number };
        albedoTexture?: { level?: number; name?: string } | null;
        emissiveTexture?: { name?: string } | null;
        metallic?: number;
        roughness?: number;
      };
      if (!/solo|additional|table light|candle/i.test(pm.name ?? "")) continue;
      out.push({
        name: pm.name,
        emisI: pm.emissiveIntensity,
        emisC: pm.emissiveColor,
        alb: pm.albedoColor,
        albLvl: pm.albedoTexture?.level,
        hasEmisTex: !!pm.emissiveTexture,
        emisTexName: pm.emissiveTexture?.name,
        albTexName: pm.albedoTexture?.name,
        metallic: pm.metallic,
        roughness: pm.roughness,
      });
    }
    return out;
  };
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
