/**
 * Simulation: step agents along every desk->POI path with separation-like
 * perturbations; assert they never penetrate a raw obstacle box
 * (except the intentional final furniture snap when sitting).
 */
import { describe, expect, it } from "vitest";
import {
  findPath,
  isWalkable,
  NAV_CLEARANCE,
  OFFICE_DESK_SLOTS,
  OFFICE_POIS,
  pointHitsObstacle,
  resolveCollision,
} from "../three/office-navdata";
import { OFFICE_PATHS } from "../three/office-paths";

function simulate(path: { x: number; z: number }[], allowLast: boolean): number {
  let violations = 0;
  let pos = { ...path[0] };
  for (let w = 1; w < path.length; w++) {
    const target = path[w];
    const lastLeg = w === path.length - 1;
    for (let step = 0; step < 500; step++) {
      const dx = target.x - pos.x;
      const dz = target.z - pos.z;
      const dist = Math.hypot(dx, dz);
      if (dist < 0.05) break;
      // Separation-like random push (up to 0.08 m per axis), mirrors runtime.
      const jx = (Math.random() - 0.5) * 0.16;
      const jz = (Math.random() - 0.5) * 0.16;
      const stepLen = Math.min(0.045, dist);
      let next = {
        x: pos.x + (dx / dist) * stepLen + jx,
        z: pos.z + (dz / dist) * stepLen + jz,
      };
      // Only keep the push when the candidate stays walkable (strict follow).
      if (!(lastLeg && allowLast && pointHitsObstacle(target))) {
        if (!isWalkable(next)) {
          next = {
            x: pos.x + (dx / dist) * stepLen,
            z: pos.z + (dz / dist) * stepLen,
          };
        }
        next = resolveCollision(next, undefined, NAV_CLEARANCE);
      }
      pos = next;
      if (pointHitsObstacle(pos) && !(lastLeg && allowLast)) violations++;
    }
    pos = { ...target };
  }
  return violations;
}

describe("walk simulation", () => {
  it("agents never penetrate furniture on desk->POI trips", () => {
    let total = 0;
    for (const seat of OFFICE_DESK_SLOTS) {
      for (const poi of OFFICE_POIS) {
        for (const slot of poi.slots) {
          const allow = slot.animation === "sitting_sofa";
          const path = findPath(seat, slot.position, { allowGoalInObstacle: allow });
          // Leg 0 leaves the desk furniture itself; runtime allows that exit.
          total += simulate(path.slice(1), allow);
        }
      }
    }
    expect(total).toBe(0);
  });

  it("agents never penetrate furniture while following patrol loops", () => {
    let total = 0;
    for (const path of OFFICE_PATHS) {
      const pts = path.loop ? [...path.waypoints, path.waypoints[0]] : path.waypoints;
      total += simulate(pts, false);
    }
    expect(total).toBe(0);
  });
});
