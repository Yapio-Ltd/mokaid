/**
 * Patrol / idle helpers built on office-navdata.
 * Patrol loops are routed through the occupancy-grid pathfinder so every
 * segment is guaranteed obstacle-free (chairs, lamps, walls, planters…).
 * Desk↔POI routes are precomputed at module load for O(1) lookup at runtime.
 */

import { Vector3 } from "@babylonjs/core";
import {
  OFFICE_DESK_SLOTS,
  OFFICE_NAV_NODES,
  OFFICE_POIS,
  findPath,
  type NavPoint,
  type SecondaryActivity,
} from "./office-navdata";

export { OFFICE_DESK_SLOTS };

export type IdleActivity =
  | "coffee"
  | "scrolling"
  | "stretch"
  | "look"
  | "playing"
  | "sitting";

export interface PathWaypoint {
  x: number;
  z: number;
  activity?: IdleActivity;
}

export interface OfficePath {
  id: string;
  waypoints: PathWaypoint[];
  loop: boolean;
}

const NODE = new Map(OFFICE_NAV_NODES.map((n) => [n.id, { x: n.x, z: n.z }]));

/**
 * Route through anchor ids; every leg uses the grid pathfinder.
 * An unknown id is skipped rather than crashing the whole scene — patrol
 * anchors move when the nav data is regenerated from the .blend.
 */
function chain(ids: string[]): PathWaypoint[] {
  const out: PathWaypoint[] = [];
  for (let k = 0; k < ids.length - 1; k++) {
    const a = NODE.get(ids[k]);
    const b = NODE.get(ids[k + 1]);
    if (!a || !b) {
      if (import.meta.env?.DEV) {
        console.warn("[office-paths] unknown anchor in loop:", ids[k], ids[k + 1]);
      }
      continue;
    }
    const leg = findPath(a, b);
    // findPath returns a single point when A* cannot connect the two anchors.
    // Chaining that in would splice a straight line between them — the patrol
    // route would cut through whatever furniture sits in between.
    if (leg.length < 2) {
      if (import.meta.env?.DEV) {
        console.warn("[office-paths] no route between anchors:", ids[k], "->", ids[k + 1]);
      }
      continue;
    }
    for (const p of leg) {
      const last = out[out.length - 1];
      if (!last || Math.hypot(p.x - last.x, p.z - last.z) > 0.05) {
        out.push({ x: p.x, z: p.z });
      }
    }
  }
  return out;
}

function loopPath(id: string, ids: string[]): OfficePath {
  return { id, loop: true, waypoints: chain(ids) };
}

/**
 * Exclusive patrol lanes (one per desk seat + extras). Agents are assigned by
 * seatIndex % length so they rarely share the same loop head-on.
 */
export const OFFICE_PATHS: OfficePath[] = [
  loopPath("perimeter-cw", [
    "n_sofa", "n_coffee", "n_east", "mid_e", "s_mid",
    "foosball_s", "sw", "mid_w", "w_aisle", "n_sofa",
  ]),
  loopPath("perimeter-ccw", [
    "n_sofa", "w_aisle", "mid_w", "sw", "foosball_s", "s_mid",
    "mid_e", "n_east", "n_coffee", "n_sofa",
  ]),
  loopPath("mid-aisle", [
    "w_aisle", "mid_w", "mid_c", "mid_e", "mid_c", "mid_w", "w_aisle",
  ]),
  loopPath("mid-aisle-rev", [
    "mid_e", "mid_c", "mid_w", "w_aisle", "mid_w", "mid_c", "mid_e",
  ]),
  loopPath("south-aisle", ["sw", "foosball_s", "s_mid", "s_mid", "foosball_s", "sw"]),
  loopPath("north-aisle", [
    "n_sofa", "n_coffee", "n_east", "n_coffee", "n_sofa",
  ]),
  loopPath("west-loop", ["w_aisle", "mid_w", "sw", "mid_w", "w_aisle"]),
  loopPath("center-loop", ["mid_w", "mid_c", "mid_e", "s_mid", "mid_c", "mid_w"]),
  loopPath("east-loop", ["mid_e", "n_east", "n_coffee", "mid_c", "mid_e"]),
  loopPath("foosball-circuit", [
    "s_mid", "foosball_s", "foosball_w", "foosball_s", "sw", "mid_w", "mid_c", "s_mid",
  ]),
  loopPath("coffee-sofa", ["n_coffee", "n_sofa", "w_aisle", "mid_w", "mid_c", "n_coffee"]),
  loopPath("cross-office", [
    "sw", "mid_w", "mid_c", "n_sofa", "n_coffee", "mid_e", "s_mid", "sw",
  ]),
];

export function pathToVectors(path: OfficePath): Vector3[] {
  return path.waypoints.map((wp) => new Vector3(wp.x, 0, wp.z));
}

/** Dedicated patrol lane for a desk seat (staggered assignment). */
export function pathForSeat(seatIndex: number, paths: OfficePath[] = OFFICE_PATHS): OfficePath {
  if (paths.length === 0) throw new Error("no patrol paths");
  const idx = ((seatIndex % paths.length) + paths.length) % paths.length;
  return paths[idx];
}

/**
 * Start index on a loop: nearest waypoint, then seat-based stagger so agents
 * on the same lane don't clump.
 */
export function staggeredWaypointIndex(
  path: OfficePath,
  x: number,
  z: number,
  seatIndex: number,
): number {
  const nearest = nearestWaypointIndex(path, x, z);
  if (path.waypoints.length === 0) return 0;
  const stride = Math.max(1, Math.floor(path.waypoints.length / Math.max(3, OFFICE_PATHS.length)));
  return (nearest + seatIndex * stride) % path.waypoints.length;
}

export function pickPathNear(
  x: number,
  z: number,
  excludeId?: string,
  paths: OfficePath[] = OFFICE_PATHS,
): OfficePath {
  let best = paths[0];
  let bestDist = Infinity;
  for (const path of paths) {
    if (path.id === excludeId) continue;
    const wp = path.waypoints[0];
    const d = (wp.x - x) ** 2 + (wp.z - z) ** 2;
    if (d < bestDist) {
      bestDist = d;
      best = path;
    }
  }
  return best;
}

export function nearestWaypointIndex(path: OfficePath, x: number, z: number): number {
  let best = 0;
  let bestDist = Infinity;
  for (let i = 0; i < path.waypoints.length; i++) {
    const wp = path.waypoints[i];
    const d = (wp.x - x) ** 2 + (wp.z - z) ** 2;
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  }
  return best;
}

export function pathFromPoints(id: string, pts: NavPoint[]): OfficePath {
  return { id, loop: false, waypoints: pts.map((p) => ({ x: p.x, z: p.z })) };
}

export function routeTo(x: number, z: number, target: NavPoint): OfficePath {
  return pathFromPoints(`route-${Date.now()}`, findPath({ x, z }, target));
}

export function patrolNodeIds(): string[] {
  return OFFICE_NAV_NODES.map((n) => n.id);
}

export function activityToSecondary(activity?: IdleActivity): SecondaryActivity {
  switch (activity) {
    case "coffee":
      return "preparing_coffee";
    case "playing":
      return "playing_foosball";
    case "sitting":
      return "sitting_sofa";
    case "scrolling":
      return "scrolling";
    case "stretch":
      return "stretching";
    case "look":
      return "looking_around";
    default:
      return null;
  }
}

/* ---------- Precomputed desk ↔ POI routes ---------- */

export interface CachedRoute {
  points: NavPoint[];
  allowGoalInObstacle: boolean;
}

function routeKey(deskIndex: number, slotId: string): string {
  return `${deskIndex}->${slotId}`;
}

function homeKey(slotId: string, deskIndex: number): string {
  return `${slotId}->desk${deskIndex}`;
}

function buildRouteCache(): {
  toPoi: Map<string, CachedRoute>;
  toDesk: Map<string, CachedRoute>;
} {
  const toPoi = new Map<string, CachedRoute>();
  const toDesk = new Map<string, CachedRoute>();
  for (let d = 0; d < OFFICE_DESK_SLOTS.length; d++) {
    const desk = OFFICE_DESK_SLOTS[d];
    for (const poi of OFFICE_POIS) {
      for (const slot of poi.slots) {
        const allow = slot.animation === "sitting_sofa";
        const outbound = findPath(desk, slot.position, { allowGoalInObstacle: allow });
        toPoi.set(routeKey(d, slot.id), { points: outbound, allowGoalInObstacle: allow });
        const inbound = findPath(slot.position, desk, { allowGoalInObstacle: true });
        toDesk.set(homeKey(slot.id, d), { points: inbound, allowGoalInObstacle: true });
      }
    }
  }
  return { toPoi, toDesk };
}

const ROUTE_CACHE = buildRouteCache();

/** Precomputed desk → POI slot polyline (raw GLB space), or null on miss. */
export function cachedDeskToPoi(deskIndex: number, slotId: string): CachedRoute | null {
  return ROUTE_CACHE.toPoi.get(routeKey(deskIndex, slotId)) ?? null;
}

/** Precomputed POI slot → desk polyline (raw GLB space), or null on miss. */
export function cachedPoiToDesk(slotId: string, deskIndex: number): CachedRoute | null {
  return ROUTE_CACHE.toDesk.get(homeKey(slotId, deskIndex)) ?? null;
}

/**
 * Best-effort route from an arbitrary raw-space point to a POI slot.
 * Prefers the cached desk→slot path when the agent is near that desk;
 * otherwise falls back to live findPath.
 */
export function routeToPoiSlot(
  from: NavPoint,
  deskIndex: number,
  slotId: string,
  slotPos: NavPoint,
  allowGoalInObstacle: boolean,
): NavPoint[] {
  const cached = cachedDeskToPoi(deskIndex, slotId);
  if (cached && cached.points.length > 1) {
    const desk = OFFICE_DESK_SLOTS[deskIndex];
    if (desk && Math.hypot(from.x - desk.x, from.z - desk.z) < 1.2) {
      return cached.points;
    }
  }
  return findPath(from, slotPos, { allowGoalInObstacle });
}

export function routeToDesk(
  from: NavPoint,
  deskIndex: number,
  deskPos: NavPoint,
  fromSlotId?: string | null,
): NavPoint[] {
  if (fromSlotId) {
    const cached = cachedPoiToDesk(fromSlotId, deskIndex);
    if (cached && cached.points.length > 1) {
      const slot = OFFICE_POIS.flatMap((p) => p.slots).find((s) => s.id === fromSlotId);
      if (slot && Math.hypot(from.x - slot.position.x, from.z - slot.position.z) < 1.2) {
        return cached.points;
      }
    }
  }
  return findPath(from, deskPos, { allowGoalInObstacle: true });
}
