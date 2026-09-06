/**
 * Shared avatar GLB loader — used in onboarding preview and office scene.
 *
 * Default character: baked male avatar with AgentVisualState clips.
 * URL resolves from VITE_ASSETS_CDN_URL + catalog path, or same-origin /assets3d/*.
 */

import {
  Animation,
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
    completeAgentAnimationTracks(container.animationGroups);
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
  }).catch((error) => {
    map.delete(url);
    throw error;
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
    true,
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
    // The office freezes its active list. Every part of a moving avatar must
    // stay eligible even when its initial desk is outside the camera frustum;
    // otherwise hair/clothes culled at spawn never reappear during a trip.
    mesh.alwaysSelectAsActiveMesh = true;
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

export function normalizeAnimName(name: string): AgentVisualState | null {
  const lower = name.toLowerCase().trim();
  // Longest aliases first: "sitting_sofa" must not resolve as a suffix token.
  for (const alias of Object.keys(CLIP_ALIASES).sort((a, b) => b.length - a.length)) {
    if (lower === alias || lower.endsWith(`/${alias}`) || lower.endsWith(`-${alias}`)) {
      return CLIP_ALIASES[alias];
    }
  }
  const parts = lower.split(/[/_\-\s]+/);
  for (let i = parts.length - 1; i >= 0; i--) {
    if (parts[i] in CLIP_ALIASES) return CLIP_ALIASES[parts[i]];
  }
  return null;
}

function findNamedNode(root: TransformNode, names: string[]): TransformNode | null {
  const want = new Set(names.map((n) => n.toLowerCase()));
  const stack: TransformNode[] = [root];
  while (stack.length) {
    const node = stack.pop()!;
    const base = node.name.split("|").pop()?.split("/").pop() ?? node.name;
    const normalized = base.toLowerCase();
    if ([...want].some((name) => normalized === name || normalized.endsWith(`-${name}`) || normalized.endsWith(`:${name}`))) return node;
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
  sit.start(false, 1.0, sit.from, sit.to, false);
  sit.goToFrame(sit.from);
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

/**
 * GLB activity clips key only a few joints; retargeted walks also translate
 * limbs. Restore unkeyed channels to the authored rest pose on every clip,
 * otherwise walking leaves stretched limbs and rotated roots behind at a seat.
 * Done once per template, before cloning or evaluating any animation.
 */
export function completeAgentAnimationTracks(groups: AnimationGroup[]) {
  const channels = new Map<TransformNode, Map<string, Animation>>();
  for (const group of groups) for (const { target, animation } of group.targetedAnimations) {
    if (!(target instanceof TransformNode)) continue;
    const property = animation.targetProperty;
    if (!["position", "rotation", "rotationQuaternion", "scaling"].includes(property)) continue;
    let properties = channels.get(target);
    if (!properties) { properties = new Map(); channels.set(target, properties); }
    properties.set(property, animation);
  }
  for (const group of groups) {
    for (const [target, properties] of channels) for (const [property, source] of properties) {
      if (group.targetedAnimations.some(track => track.target === target && track.animation.targetProperty === property)) continue;
      const value = property === "position" ? target.position
        : property === "rotation" ? target.rotation
        : property === "scaling" ? target.scaling : target.rotationQuaternion;
      if (!value) continue;
      const track = new Animation(`${group.name}-rest-${property}`, property, source.framePerSecond, source.dataType);
      track.setKeys([{ frame: group.from, value: value.clone() }, { frame: group.to, value: value.clone() }]);
      group.addTargetedAnimation(track, target);
    }
  }
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

interface AnimationBlend {
  target: AnimationGroup;
  weights: Map<AnimationGroup, number>;
  elapsed: number;
}
const blends = new WeakMap<AgentAnimPlayer, AnimationBlend>();
const BLEND_SECONDS = 0.28;

/** Advance only active crossfades; completed poses need no per-frame allocations. */
export function advanceAgentAnimation(avatar: AgentAnimPlayer, dt: number) {
  const blend = blends.get(avatar);
  if (!blend) return;
  blend.elapsed += Math.max(0, Math.min(dt, 0.05));
  const u = Math.min(1, blend.elapsed / BLEND_SECONDS);
  const weight = u * u * (3 - 2 * u);
  for (const [group, from] of blend.weights) {
    group.weight = from + ((group === blend.target ? 1 : 0) - from) * weight;
    if (u === 1 && group !== blend.target) group.stop();
  }
  if (u === 1) blends.delete(avatar);
}

export function playAgentAnimation(avatar: AgentAnimPlayer, next: AgentAnimName) {
  const { state, group } = resolveClip(avatar, next);
  if (!group || avatar.currentAnim === state) return;
  const groups = new Set([...Object.values(avatar.anims), avatar.idleAnim, avatar.walkAnim]);
  const weights = new Map<AnimationGroup, number>();
  for (const ag of groups) {
    if (ag?.isPlaying) weights.set(ag, Math.max(0, ag.weight < 0 ? 1 : ag.weight));
  }
  avatar.currentAnim = state;
  // Multiple missing states may resolve to the same idle clip. Keep its phase.
  if (weights.size === 1 && weights.has(group)) return;
  if (!group.isPlaying) {
    group.weight = weights.size ? 0 : 1;
    group.start(state !== "celebrating", 1, group.from, group.to, false);
  }
  weights.set(group, group.weight < 0 ? 1 : group.weight);
  if (weights.size === 1) {
    group.weight = 1;
    blends.delete(avatar);
  } else {
    blends.set(avatar, { target: group, weights, elapsed: 0 });
  }
}

/** Match the authored in-place stride to real travel, including avoidance braking. */
export function setAgentWalkSpeed(avatar: AgentAnimPlayer, metersPerSecond: number) {
  const walk = avatar.anims.walking ?? avatar.walkAnim;
  if (walk) walk.speedRatio = Math.max(0.05, Math.min(1.6, metersPerSecond / 1.5));
}

export function disposeAgentAnims(avatar: { anims?: AgentAnimMap; idleAnim?: AnimationGroup | null; walkAnim?: AnimationGroup | null }) {
  blends.delete(avatar as AgentAnimPlayer);
  for (const ag of new Set([...Object.values(avatar.anims ?? {}), avatar.idleAnim, avatar.walkAnim])) {
    ag?.dispose();
  }
}

/** Release per-avatar GPU resources while keeping cached geometry/textures alive. */
export function disposeAgentModel(avatar: { root: TransformNode; meshes: AbstractMesh[] }) {
  const materials = new Set(avatar.meshes.map(mesh => mesh.material));
  const skeletons = new Set(avatar.meshes.map(mesh => mesh.skeleton));
  avatar.root.dispose();
  for (const skeleton of skeletons) skeleton?.dispose();
  for (const material of materials) material?.dispose(false, false);
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
 * is shown on the floating label, not a floor marker.
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
