/**
 * Babylon collision proxies for the 3D office.
 * Invisible obstacle boxes in **centered world space** + per-avatar ellipsoids.
 */

import {
  Color3,
  Mesh,
  MeshBuilder,
  Scene,
  StandardMaterial,
  Vector3,
} from "@babylonjs/core";
import { OFFICE_OBSTACLES, type Aabb2 } from "./office-navdata";

/** Horizontal ellipsoid radii (XZ) and half-height (Y). */
export const AGENT_ELLIPSOID = new Vector3(0.38, 0.95, 0.38);
export const AGENT_ELLIPSOID_OFFSET = new Vector3(0, 0.95, 0);

const COLLIDER_HEIGHT = 2.4;
/** Extra inflate on each axis (meters) so agents cannot skim through thin walls. */
const BOX_PAD = 0.06;

/**
 * Build invisible collision boxes for every raw obstacle AABB, placed in the
 * centered scene frame (raw − centerOffset). Not parented — Babylon's
 * moveWithCollisions is more reliable with world-space colliders.
 */
export function createObstacleColliders(
  scene: Scene,
  centerOffset: { x: number; y: number; z: number },
  obstacles: Aabb2[] = OFFICE_OBSTACLES,
): Mesh[] {
  scene.collisionsEnabled = true;

  let mat = scene.getMaterialByName("office-collider-mat") as StandardMaterial | null;
  if (!mat) {
    mat = new StandardMaterial("office-collider-mat", scene);
    mat.disableLighting = true;
    mat.diffuseColor = new Color3(1, 0, 0);
    mat.alpha = 0;
    mat.transparencyMode = StandardMaterial.MATERIAL_ALPHABLEND;
  }

  const meshes: Mesh[] = [];
  for (let i = 0; i < obstacles.length; i++) {
    const o = obstacles[i];
    const w = Math.max(0.08, o.maxX - o.minX + BOX_PAD * 2);
    const d = Math.max(0.08, o.maxZ - o.minZ + BOX_PAD * 2);
    const box = MeshBuilder.CreateBox(
      `office-collider-${i}`,
      { width: w, height: COLLIDER_HEIGHT, depth: d },
      scene,
    );
    box.position.set(
      (o.minX + o.maxX) / 2 - centerOffset.x,
      COLLIDER_HEIGHT / 2,
      (o.minZ + o.maxZ) / 2 - centerOffset.z,
    );
    box.isVisible = false;
    box.isPickable = false;
    box.checkCollisions = true;
    box.isNearGrabbable = false;
    box.material = mat;
    meshes.push(box);
  }
  return meshes;
}

/** Invisible collision proxy for an agent avatar (world-space, not parented). */
export function createAgentCollider(scene: Scene, id: string): Mesh {
  scene.collisionsEnabled = true;
  // Box ellipsoid carrier — more reliable than capsule for moveWithCollisions.
  const carrier = MeshBuilder.CreateBox(
    `agent-collider-${id}`,
    { width: 0.5, height: 1.8, depth: 0.5 },
    scene,
  );
  carrier.isVisible = false;
  carrier.isPickable = false;
  carrier.checkCollisions = true;
  carrier.ellipsoid = AGENT_ELLIPSOID.clone();
  carrier.ellipsoidOffset = AGENT_ELLIPSOID_OFFSET.clone();
  return carrier;
}

export function setAgentCollisionsEnabled(collider: Mesh, enabled: boolean) {
  collider.checkCollisions = enabled;
}

/**
 * Move an agent collider with Babylon ellipsoid collisions, then sync the
 * visual root XZ (Y is owned by plantFeet / seat blend).
 */
export function moveAgentWithCollisions(
  collider: Mesh,
  root: { position: Vector3 },
  dx: number,
  dz: number,
): void {
  collider.position.x = root.position.x;
  collider.position.y = Math.max(AGENT_ELLIPSOID_OFFSET.y, root.position.y + AGENT_ELLIPSOID_OFFSET.y);
  collider.position.z = root.position.z;
  if (Math.abs(dx) < 1e-8 && Math.abs(dz) < 1e-8) return;
  collider.moveWithCollisions(new Vector3(dx, 0, dz));
  root.position.x = collider.position.x;
  root.position.z = collider.position.z;
}

export function syncColliderToRoot(collider: Mesh, root: { position: Vector3 }) {
  collider.position.x = root.position.x;
  collider.position.y = Math.max(AGENT_ELLIPSOID_OFFSET.y, root.position.y + AGENT_ELLIPSOID_OFFSET.y);
  collider.position.z = root.position.z;
}

export function disposeObstacleColliders(meshes: Mesh[]) {
  for (const m of meshes) m.dispose();
  meshes.length = 0;
}
