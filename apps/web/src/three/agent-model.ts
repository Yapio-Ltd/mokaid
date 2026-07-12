/**
 * Shared avatar GLB loader — used in onboarding preview and office scene.
 *
 * Default character: baked male avatar with AgentVisualState clips.
 * URL resolves from VITE_ASSETS_CDN_URL + catalog path, or same-origin /assets3d/*.
 */

import {
  AnimationGroup,
  AssetContainer,
  Color3,
  PBRMaterial,
  Scene,
  SceneLoader,
  StandardMaterial,
  TransformNode,
  Vector3,
} from "@babylonjs/core";
import "@babylonjs/loaders/glTF";
import type { AbstractMesh } from "@babylonjs/core";
import type { AgentVisualState } from "@mokaid/shared-types";
import { env } from "@/lib/env";

/** Hashed filename matching assets/optimized + S3 upload + asset_3d seed. */
export const DEFAULT_AVATAR_CDN_PATH = "/assets3d/avatar_male.fb67abfedaea.glb";

const VISUAL_STATES: AgentVisualState[] = [
  "idle",
  "walking",
  "working",
  "typing",
  "thinking",
  "talking",
  "waiting",
  "blocked",
  "celebrating",
  "away",
  "offline",
  "reviewing",
  "learning",
  "requesting_approval",
];

/** Clip name aliases → AgentVisualState (GLB + Mixamo + legacy). */
const CLIP_ALIASES: Record<string, AgentVisualState> = {
  idle: "idle",
  walk: "walking",
  walking: "walking",
  walking_man: "walking",
  typing: "typing",
  working: "working",
  thinking: "thinking",
  talking: "talking",
  waiting: "waiting",
  blocked: "blocked",
  celebrating: "celebrating",
  away: "away",
  offline: "offline",
  reviewing: "reviewing",
  learning: "learning",
  requesting_approval: "requesting_approval",
};

export type AgentAnimName = AgentVisualState | "walk";

export function resolveAgentGlbUrl(cdnPath?: string | null): string {
  const path = (cdnPath && cdnPath.trim()) || DEFAULT_AVATAR_CDN_PATH;
  if (path.startsWith("http://") || path.startsWith("https://")) return path;
  const base = env.VITE_ASSETS_CDN_URL.trim().replace(/\/$/, "");
  if (!base) return path.startsWith("/") ? path : `/${path}`;
  return `${base}${path.startsWith("/") ? path : `/${path}`}`;
}

/** @deprecated Prefer resolveAgentGlbUrl() — kept for existing imports. */
export const AGENT_GLB_URL = resolveAgentGlbUrl();

const TARGET_HEIGHT = 1.75;

export type AgentAnimMap = Partial<Record<AgentVisualState, AnimationGroup | null>>;

export interface AgentModelTemplate {
  container: AssetContainer;
  anims: AgentAnimMap;
  /** @deprecated use anims.idle */
  idleAnim: AnimationGroup | null;
  /** @deprecated use anims.walking */
  walkAnim: AnimationGroup | null;
  scale: number;
  footOffset: number;
  url: string;
}

export interface SpawnedAgentModel {
  root: TransformNode;
  meshes: AbstractMesh[];
  anims: AgentAnimMap;
  idleAnim: AnimationGroup | null;
  walkAnim: AnimationGroup | null;
  labelHeight: number;
}

export interface AgentAnimPlayer {
  anims: AgentAnimMap;
  idleAnim: AnimationGroup | null;
  walkAnim: AnimationGroup | null;
  currentAnim: AgentAnimName | null;
}

// Cache per scene so that disposing a scene (e.g. when navigating away and back)
// never returns a stale AssetContainer linked to the old Babylon engine.
const templateCache = new WeakMap<Scene, Map<string, Promise<AgentModelTemplate>>>();

function cacheFor(scene: Scene): Map<string, Promise<AgentModelTemplate>> {
  let map = templateCache.get(scene);
  if (!map) {
    map = new Map();
    templateCache.set(scene, map);
  }
  return map;
}

export function loadAgentModelTemplate(
  scene: Scene,
  cdnPathOrUrl?: string | null,
): Promise<AgentModelTemplate> {
  const url = resolveAgentGlbUrl(cdnPathOrUrl);
  const map = cacheFor(scene);
  const cached = map.get(url);
  if (cached) return cached;

  const promise = SceneLoader.LoadAssetContainerAsync("", url, scene).then((container) => {
    const probe = container.instantiateModelsToScene((name) => `probe-${name}`, false, {
      doNotInstantiate: false,
    });

    const root = probe.rootNodes[0] as TransformNode | undefined;
    let scale = 1;
    let footOffset = 0;

    if (root) {
      // Mixamo exports often put 0.01 on Armature (cm→m). Measure against a
      // unit root scale so spawn can apply an absolute meters scale.
      root.scaling.setAll(1);
      root.computeWorldMatrix(true);
      const bounds = root.getHierarchyBoundingVectors(true);
      const height = bounds.max.y - bounds.min.y;
      scale = height > 0 ? TARGET_HEIGHT / height : 1;
      footOffset = -bounds.min.y * scale;
    }

    probe.rootNodes.forEach((n) => n.dispose());
    probe.skeletons.forEach((s) => s.dispose());
    probe.animationGroups.forEach((ag) => ag.dispose());

    const anims = indexAnims(container.animationGroups);
    return {
      container,
      anims,
      idleAnim: anims.idle ?? null,
      walkAnim: anims.walking ?? null,
      scale,
      footOffset,
      url,
    };
  });

  map.set(url, promise);
  return promise;
}

export function spawnAgentModel(
  template: AgentModelTemplate,
  scene: Scene,
  agentId: string,
  color: string,
): SpawnedAgentModel {
  const instance = template.container.instantiateModelsToScene(
    (name) => `agent-${agentId}-${name}`,
    false,
    { doNotInstantiate: false },
  );

  const root =
    (instance.rootNodes[0] as TransformNode) ?? new TransformNode(`agent-${agentId}`, scene);
  root.scaling.setAll(template.scale);
  // glTF import sets rotationQuaternion, which silently overrides `.rotation` —
  // clear it so the walk/idle state machine's Euler rotation.y takes effect.
  root.rotationQuaternion = null;

  const meshes: AbstractMesh[] = [];
  for (const node of instance.rootNodes) {
    meshes.push(...node.getChildMeshes(false));
  }

  applyTint(meshes, color);

  for (const mesh of meshes) {
    mesh.isPickable = true;
    mesh.metadata = { agentId };
  }

  root.computeWorldMatrix(true);
  const bounds = root.getHierarchyBoundingVectors(true);
  const labelHeight = bounds.max.y - root.position.y + 0.25;

  const anims = indexAnims(instance.animationGroups);

  return {
    root,
    meshes,
    anims,
    idleAnim: anims.idle ?? null,
    walkAnim: anims.walking ?? null,
    labelHeight,
  };
}

function normalizeAnimName(name: string): AgentVisualState | null {
  const lower = name.toLowerCase().trim();
  // Strip Babylon prefixes like "agent-uuid-idle"
  const parts = lower.split(/[\/_\-\s]+/);
  for (let i = parts.length - 1; i >= 0; i--) {
    const part = parts[i];
    if (part in CLIP_ALIASES) return CLIP_ALIASES[part];
  }
  for (const [alias, state] of Object.entries(CLIP_ALIASES)) {
    if (lower === alias || lower.endsWith(`/${alias}`) || lower.endsWith(`-${alias}`)) {
      return state;
    }
  }
  return null;
}

function indexAnims(groups: AnimationGroup[]): AgentAnimMap {
  const map: AgentAnimMap = {};
  for (const ag of groups) {
    const state = normalizeAnimName(ag.name);
    if (state && !map[state]) map[state] = ag;
  }
  // Ensure all known states exist as keys (null if missing)
  for (const state of VISUAL_STATES) {
    if (!(state in map)) map[state] = null;
  }
  return map;
}

function resolveClip(
  avatar: AgentAnimPlayer,
  next: AgentAnimName,
): { state: AgentVisualState; group: AnimationGroup | null } {
  const state: AgentVisualState = next === "walk" ? "walking" : next;
  const group =
    avatar.anims[state] ??
    (state === "walking" ? avatar.walkAnim : null) ??
    (state === "idle" ? avatar.idleAnim : null) ??
    avatar.anims.idle ??
    avatar.idleAnim ??
    null;
  return { state, group };
}

export function playAgentAnimation(avatar: AgentAnimPlayer, next: AgentAnimName) {
  const { state, group } = resolveClip(avatar, next);
  if (avatar.currentAnim === state || (next === "walk" && avatar.currentAnim === "walking")) {
    return;
  }

  for (const ag of Object.values(avatar.anims)) {
    ag?.stop();
  }
  avatar.idleAnim?.stop();
  avatar.walkAnim?.stop();

  const loop = state !== "celebrating";
  if (group) {
    group.start(loop, 1.0, group.from, group.to, false);
  } else {
    const idle = avatar.anims.idle ?? avatar.idleAnim;
    idle?.start(true);
  }
  avatar.currentAnim = state;
}

export function disposeAgentAnims(avatar: { anims?: AgentAnimMap; idleAnim?: AnimationGroup | null; walkAnim?: AnimationGroup | null }) {
  for (const ag of Object.values(avatar.anims ?? {})) {
    ag?.dispose();
  }
  avatar.idleAnim?.dispose();
  avatar.walkAnim?.dispose();
}

export function groundAgent(root: TransformNode, footOffset: number) {
  root.position.y = footOffset;
}

function hexToColor3(hex: string): Color3 {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  return new Color3(r, g, b);
}

/**
 * Legacy solid tint for untextured placeholder meshes (e.g. RobotExpressive).
 * Realistic catalog avatars keep their authored materials/textures — agent color
 * is shown via the status ring instead.
 */
export function applyTint(meshes: AbstractMesh[], hex: string) {
  const hasAuthoringTextures = meshes.some((mesh) => {
    const mat = mesh.material;
    if (mat instanceof PBRMaterial) {
      return Boolean(mat.albedoTexture || mat.bumpTexture || mat.opacityTexture);
    }
    if (mat instanceof StandardMaterial) {
      return Boolean(mat.diffuseTexture || mat.bumpTexture || mat.opacityTexture);
    }
    return false;
  });
  if (hasAuthoringTextures) return;

  const tint = hexToColor3(hex);
  for (const mesh of meshes) {
    if (!mesh.material) continue;
    // Clone so each agent gets an independent color without mutating the template.
    if (mesh.material instanceof PBRMaterial) {
      const cloned = mesh.material.clone(`${mesh.material.name}-tint`) ?? mesh.material;
      cloned.albedoColor = tint;
      mesh.material = cloned;
    } else if (mesh.material instanceof StandardMaterial) {
      const cloned = mesh.material.clone(`${mesh.material.name}-tint`) ?? mesh.material;
      cloned.diffuseColor = tint;
      mesh.material = cloned;
    }
  }
}

/** Project a position onto the walkable floor (y = 0). */
export function toFloor(x: number, z: number): Vector3 {
  return new Vector3(x, 0, z);
}
