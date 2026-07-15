/**
 * Patrol / idle helpers built on office-navdata.
 * Desk slots and POIs live in office-navdata.ts (single source of truth).
 */

import { Vector3 } from "@babylonjs/core";
import {
  OFFICE_DESK_SLOTS,
  OFFICE_NAV_NODES,
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

/** Patrol loops derived from the nav graph perimeter / aisles. */
export const OFFICE_PATHS: OfficePath[] = [
  {
    id: "perimeter",
    loop: true,
    waypoints: [
      { x: -5.6, z: -5.2 },
      { x: -0.5, z: -5.2 },
      { x: 5.4, z: -5.2 },
      { x: 5.5, z: -0.4 },
      { x: 4.6, z: 2.6 },
      { x: -1.0, z: 3.4 },
      { x: -5.4, z: 3.2 },
      { x: -5.6, z: -0.8 },
    ],
  },
  {
    id: "mid-aisle",
    loop: true,
    waypoints: [
      { x: -5.6, z: -0.8 },
      { x: -3.0, z: -1.6 },
      { x: 0.4, z: -1.8 },
      { x: 3.5, z: -1.4 },
      { x: 5.5, z: -0.4 },
      { x: 3.5, z: -1.4 },
      { x: -3.0, z: -1.6 },
    ],
  },
  {
    id: "back-aisle",
    loop: true,
    waypoints: [
      { x: -5.4, z: 3.2 },
      { x: -1.0, z: 3.4 },
      { x: 2.2, z: 3.4 },
      { x: 4.6, z: 2.6 },
      { x: 2.2, z: 3.4 },
      { x: -5.4, z: 3.2 },
    ],
  },
];

export function pathToVectors(path: OfficePath): Vector3[] {
  return path.waypoints.map((wp) => new Vector3(wp.x, 0, wp.z));
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
  path.waypoints.forEach((wp, i) => {
    const d = (wp.x - x) ** 2 + (wp.z - z) ** 2;
    if (d < bestDist) {
      bestDist = d;
      best = i;
    }
  });
  return best;
}

/** Build a path object from an A* polyline (non-looping). */
export function pathFromPoints(id: string, points: NavPoint[]): OfficePath {
  return {
    id,
    loop: false,
    waypoints: points.map((p) => ({ x: p.x, z: p.z })),
  };
}

export function routeTo(x: number, z: number, target: NavPoint): OfficePath {
  return pathFromPoints(`route-${Date.now()}`, findPath({ x, z }, target));
}

export function allNavNodeIds(): string[] {
  return OFFICE_NAV_NODES.map((n) => n.id);
}

export function idleToSecondary(activity: IdleActivity): SecondaryActivity {
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
