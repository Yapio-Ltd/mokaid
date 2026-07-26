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
import {
  AGENT_GLB_URL,
  DEFAULT_AVATAR_CDN_PATH,
  resolveAgentGlbUrl,
} from "./agent-cdn";

export { AGENT_GLB_URL, DEFAULT_AVATAR_CDN_PATH, resolveAgentGlbUrl };

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
  "sitting",
  "preparing_coffee",
  "playing_foosball",
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
  sitting: "sitting",
  sitting_sofa: "sitting",
  sit: "sitting",
  preparing_coffee: "preparing_coffee",
  coffee: "preparing_coffee",
  playing_foosball: "playing_foosball",
  foosball: "playing_foosball",
};

export type AgentAnimName =
  | AgentVisualState
  | "walk"
  | "sitting"
  | "preparing_coffee"
  | "playing_foosball";

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
  /**
   * World-space pelvis height above the avatar root while the `sitting` clip
   * is held on its first frame (after scale). Used to plant the hips on a sofa
   * cushion: `root.y = seatY - sitPelvisHeight`.
   */
  sitPelvisHeight: number;
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
    let sitPelvisHeight = 0.58;

    if (root) {
      // Mixamo exports often put 0.01 on Armature (cm→m). Measure against a
      // unit root scale so spawn can apply an absolute meters scale.
      root.scaling.setAll(1);
      root.computeWorldMatrix(true);
      const bounds = root.getHierarchyBoundingVectors(true);
      const height = bounds.max.y - bounds.min.y;
      scale = height > 0 ? TARGET_HEIGHT / height : 1;
      footOffset = -bounds.min.y * scale;
      sitPelvisHeight = measureSitPelvisHeight(root, probe.animationGroups, scale, footOffset);
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
      sitPelvisHeight,
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
  const parts = lower.split(/[/_\-\s]+/);
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

function findNamedNode(root: TransformNode, names: string[]): TransformNode | null {
  const want = new Set(names.map((n) => n.toLowerCase()));
  const stack: TransformNode[] = [root];
  while (stack.length) {
    const node = stack.pop()!;
    const base = node.name.split("|").pop()?.split("/").pop() ?? node.name;
    if (want.has(base.toLowerCase()) || want.has(node.name.toLowerCase())) return node;
    for (const child of node.getChildren()) {
      if (child instanceof TransformNode) stack.push(child);
    }
  }
  return null;
}

/**
 * Hold the sitting clip on its first frame and read pelvis height above root.
 * Falls back to a Mixamo-scaled estimate when the clip or bone is missing.
 */
function measureSitPelvisHeight(
  root: TransformNode,
  animationGroups: AnimationGroup[],
  scale: number,
  footOffset: number,
): number {
  const FALLBACK = 0.58;
  root.scaling.setAll(scale);
  root.position.set(0, footOffset, 0);
  root.rotationQuaternion = null;
  root.rotation.set(0, 0, 0);

  const sit = animationGroups.find((g) => normalizeAnimName(g.name) === "sitting");
  if (!sit) return FALLBACK;

  for (const ag of animationGroups) ag.stop();
  sit.start(false, 1.0, sit.from, sit.from, false);
  root.computeWorldMatrix(true);

  const hips =
    findNamedNode(root, ["Hips", "hips", "root.x", "pelvis", "Pelvis"]) ?? null;
  if (!hips) {
    sit.stop();
    return FALLBACK;
  }
  hips.computeWorldMatrix(true);
  const height = hips.getAbsolutePosition().y - root.position.y;
  sit.stop();
  return height > 0.2 && height < 1.3 ? height : FALLBACK;
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
  const state = (next === "walk" ? "walking" : next) as AgentVisualState;
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
    // Re-assert playback if the group stalled (e.g. after a failed prior fallback).
    if (group && !group.isPlaying) {
      group.start(state !== "celebrating", 1.0, group.from, group.to, false);
    }
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
    avatar.currentAnim = state;
  } else {
    // Don't claim the missing state — keep retrying next frame when the clip appears.
    const idle = avatar.anims.idle ?? avatar.idleAnim;
    idle?.start(true);
    avatar.currentAnim = "idle";
    if (state !== "idle") {
      console.warn(`[agent-model] missing clip "${state}", falling back to idle`);
    }
  }
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
