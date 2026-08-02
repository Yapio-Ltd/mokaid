/**
 * Recast Navigation + Crowd locomotion for the 3D office.
 * Best practice Babylon/AI: constrain agents to a navmesh and let Detour Crowd
 * handle pathfollowing + agent–agent avoidance (replaces handmade walkToward).
 */

import {
  Crowd,
  type CrowdAgent,
  init as initRecast,
  NavMesh,
  NavMeshQuery,
} from "recast-navigation";
import { generateSoloNavMesh } from "recast-navigation/generators";
import {
  AGENT_RADIUS,
  OFFICE_OBSTACLES,
  OFFICE_WALKABLE_POLYGON,
  type Aabb2,
  type NavPoint,
} from "./office-navdata";

export const CROWD_AGENT_RADIUS = AGENT_RADIUS;
export const CROWD_MAX_AGENTS = 16;
export const CROWD_WALK_SPEED = 1.55;
/** Speed below this → idle anim (not walking-in-place). */
export const CROWD_MOVE_EPS = 0.08;

const FLOOR_STEP = 0.2;
/**
 * Hole pad around furniture AABBs when rasterizing the floor mesh.
 *
 * This pad is now the *only* clearance between an agent and furniture, since
 * the navmesh bakes with `walkableRadius: 0` (see createOfficeCrowd). Sweeping
 * it against real routes, connectivity breaks at 0.16 where the aisle past the
 * kitchenette closes. 0.12 still connects, but only for some sampling offsets —
 * the rasteriser aligns to centerOffset, so a 0.12 floor is one grid phase away
 * from splitting. 0.08 keeps the office connected at every offset.
 */
const OBSTACLE_PAD = 0.08;
/** Reject findClosestPoint results farther than this (prevents island teleport). */
const MAX_SNAP_DIST = 1.35;

let recastReady: Promise<void> | null = null;

export function ensureRecastInit(): Promise<void> {
  if (!recastReady) {
    recastReady = initRecast().then(() => undefined);
  }
  return recastReady;
}

function pointInObstacle(x: number, z: number, obstacles: Aabb2[], pad: number): boolean {
  for (const o of obstacles) {
    if (
      x >= o.minX - pad &&
      x <= o.maxX + pad &&
      z >= o.minZ - pad &&
      z <= o.maxZ + pad
    ) {
      return true;
    }
  }
  return false;
}

function pointInPolygon(p: NavPoint, poly: NavPoint[]): boolean {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const xi = poly[i].x;
    const zi = poly[i].z;
    const xj = poly[j].x;
    const zj = poly[j].z;
    const intersect =
      zi > p.z !== zj > p.z && p.x < ((xj - xi) * (p.z - zi)) / (zj - zi + 1e-12) + xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

/**
 * Build a Y-up floor mesh with holes where obstacles (+ clearance) sit.
 * Coordinates are in **centered scene space** (raw − centerOffset) so they
 * match avatar.root positions.
 * Triangle winding matches Recast/OpenGL (validated against generateSoloNavMesh).
 */
export function buildOfficeFloorMesh(
  centerOffset: { x: number; z: number },
  obstacles: Aabb2[] = OFFICE_OBSTACLES,
  polygon: NavPoint[] = OFFICE_WALKABLE_POLYGON,
): { positions: number[]; indices: number[] } {
  let minX = Infinity;
  let maxX = -Infinity;
  let minZ = Infinity;
  let maxZ = -Infinity;
  for (const p of polygon) {
    minX = Math.min(minX, p.x - centerOffset.x);
    maxX = Math.max(maxX, p.x - centerOffset.x);
    minZ = Math.min(minZ, p.z - centerOffset.z);
    maxZ = Math.max(maxZ, p.z - centerOffset.z);
  }

  const positions: number[] = [];
  const indices: number[] = [];
  const nx = Math.ceil((maxX - minX) / FLOOR_STEP);
  const nz = Math.ceil((maxZ - minZ) / FLOOR_STEP);

  for (let iz = 0; iz < nz; iz++) {
    for (let ix = 0; ix < nx; ix++) {
      const x0 = minX + ix * FLOOR_STEP;
      const z0 = minZ + iz * FLOOR_STEP;
      const x1 = x0 + FLOOR_STEP;
      const z1 = z0 + FLOOR_STEP;
      const cx = (x0 + x1) / 2;
      const cz = (z0 + z1) / 2;
      // Obstacle tests stay in raw GLB space.
      const raw = { x: cx + centerOffset.x, z: cz + centerOffset.z };
      if (!pointInPolygon(raw, polygon)) continue;
      if (pointInObstacle(raw.x, raw.z, obstacles, OBSTACLE_PAD)) continue;

      const base = positions.length / 3;
      // verts: 0=(-,-) 1=(+,-) 2=(+,+) 3=(-,+)
      positions.push(x0, 0, z0, x1, 0, z0, x1, 0, z1, x0, 0, z1);
      // Winding that Recast accepts as walkable (see probe: [0,2,1,0,3,2]).
      indices.push(base, base + 2, base + 1, base, base + 3, base + 2);
    }
  }
  return { positions, indices };
}

export interface OfficeCrowd {
  navMesh: NavMesh;
  query: NavMeshQuery;
  crowd: Crowd;
  destroy(): void;
}

export async function createOfficeCrowd(
  centerOffset: { x: number; z: number },
  obstacles: Aabb2[] = OFFICE_OBSTACLES,
): Promise<OfficeCrowd | null> {
  await ensureRecastInit();
  const { positions, indices } = buildOfficeFloorMesh(centerOffset, obstacles);
  if (indices.length < 6) {
    console.warn("[office-crowd] floor mesh empty — crowd disabled");
    return null;
  }

  const cs = 0.15;
  const result = generateSoloNavMesh(positions, indices, {
    cs,
    ch: 0.2,
    walkableSlopeAngle: 45,
    walkableHeight: 10,
    walkableClimb: 1,
    // 0, not 1: the floor mesh already carves OBSTACLE_PAD around every
    // AABB, so eroding again cost a second 0.15 m on each side. That closed
    // the narrow aisles either side of the partition and split the navmesh —
    // the west wing became unreachable and agents routed across it walked
    // into the pinch and looped forever in crowd-recover.
    walkableRadius: 0,
    maxEdgeLen: 12,
    maxSimplificationError: 1.3,
    minRegionArea: 2,
    mergeRegionArea: 4,
    maxVertsPerPoly: 6,
    detailSampleDist: 6,
    detailSampleMaxError: 1,
    buildBvTree: true,
  });

  if (!result.success || !result.navMesh) {
    console.warn("[office-crowd] navmesh bake failed:", result.error);
    return null;
  }

  const navMesh = result.navMesh;
  const query = new NavMeshQuery(navMesh);
  const crowd = new Crowd(navMesh, {
    maxAgents: CROWD_MAX_AGENTS,
    maxAgentRadius: CROWD_AGENT_RADIUS + 0.15,
  });

  return {
    navMesh,
    query,
    crowd,
    destroy() {
      crowd.destroy();
      navMesh.destroy();
    },
  };
}

export function crowdClosestPoint(
  query: NavMeshQuery,
  x: number,
  z: number,
  y = 0,
): { x: number; y: number; z: number } {
  let best: { x: number; y: number; z: number } | null = null;
  let bestDist = Infinity;
  for (const ext of [0.8, 1.5, 2.5, 4]) {
    const result = query.findClosestPoint(
      { x, y, z },
      { halfExtents: { x: ext, y: 2, z: ext } },
    );
    if (!result.success) continue;
    const d = Math.hypot(result.point.x - x, result.point.z - z);
    if (d < bestDist) {
      bestDist = d;
      best = { x: result.point.x, y: result.point.y, z: result.point.z };
    }
    // Good enough — stop expanding (avoids leaping to a remote island).
    if (best && bestDist <= MAX_SNAP_DIST) return best;
  }
  if (best && bestDist <= MAX_SNAP_DIST * 1.5) return best;
  // Stay put rather than teleport across the office.
  return { x, y: y + 0.2, z };
}

/** True when a centered-scene point maps into a raw furniture AABB. */
export function crowdPointInFurniture(
  centeredX: number,
  centeredZ: number,
  centerOffset: { x: number; z: number },
  /** Default 0 — padded checks false-positive in narrow aisles and thrash recover. */
  pad = 0,
): boolean {
  return pointInObstacle(
    centeredX + centerOffset.x,
    centeredZ + centerOffset.z,
    OFFICE_OBSTACLES,
    pad,
  );
}

/** Nearest navmesh point to a raw-space approach / socket, in centered coords. */
export function crowdNavTarget(
  query: NavMeshQuery,
  rawX: number,
  rawZ: number,
  centerOffset: { x: number; z: number },
): { x: number; z: number } {
  const cx = rawX - centerOffset.x;
  const cz = rawZ - centerOffset.z;
  const p = crowdClosestPoint(query, cx, cz);
  return { x: p.x, z: p.z };
}

/**
 * Detour `updateFlags` bits. `separationWeight` is only read when
 * SEPARATION is set — without it the weight was dead config and agents
 * shouldered each other through doorways.
 */
export const CROWD_ANTICIPATE_TURNS = 1;
export const CROWD_OBSTACLE_AVOIDANCE = 2;
export const CROWD_SEPARATION = 4;
export const CROWD_OPTIMIZE_VIS = 8;
export const CROWD_OPTIMIZE_TOPO = 16;
export const CROWD_UPDATE_FLAGS =
  CROWD_ANTICIPATE_TURNS |
  CROWD_OBSTACLE_AVOIDANCE |
  CROWD_SEPARATION |
  CROWD_OPTIMIZE_VIS |
  CROWD_OPTIMIZE_TOPO;

export function addCrowdAgent(
  crowd: Crowd,
  query: NavMeshQuery,
  x: number,
  z: number,
): CrowdAgent | null {
  const pos = crowdClosestPoint(query, x, z);
  try {
    return crowd.addAgent(pos, {
      // Slightly larger than the body so Detour reserves personal space
      // instead of letting shoulders touch.
      radius: CROWD_AGENT_RADIUS * 1.35,
      height: 1.8,
      // Reaching full speed in ~0.25 s keeps starts crisp without the
      // snap that made avatars slide before the walk cycle caught up.
      maxAcceleration: 6,
      maxSpeed: CROWD_WALK_SPEED,
      collisionQueryRange: CROWD_AGENT_RADIUS * 8,
      pathOptimizationRange: CROWD_AGENT_RADIUS * 24,
      // Detour keeps agents apart by *radius*, so two 0.35 m bodies can close
      // to 0.7 m centre-to-centre and still be "separated". The office reads
      // as crowded well before that, so ask for a wider berth and lean on the
      // separation force to hold it in the aisles.
      separationWeight: 2.6,
      updateFlags: CROWD_UPDATE_FLAGS,
      obstacleAvoidanceType: 3,
      queryFilterType: 0,
      userData: 0,
    });
  } catch (err) {
    console.warn("[office-crowd] addAgent failed", err);
    return null;
  }
}

export function crowdGoto(
  agent: CrowdAgent,
  query: NavMeshQuery,
  x: number,
  z: number,
): void {
  const dest = crowdClosestPoint(query, x, z);
  agent.requestMoveTarget(dest);
}

export function crowdTeleport(
  agent: CrowdAgent,
  query: NavMeshQuery,
  x: number,
  z: number,
): void {
  const dest = crowdClosestPoint(query, x, z);
  agent.teleport(dest);
}

/** Detour agent state: 0 = invalid / off mesh. */
export function crowdAgentIsStuck(agent: CrowdAgent): boolean {
  try {
    return agent.state() === 0;
  } catch {
    return true;
  }
}

export function crowdSpeed(agent: CrowdAgent): number {
  const v = agent.velocity();
  return Math.hypot(v.x, v.z);
}
