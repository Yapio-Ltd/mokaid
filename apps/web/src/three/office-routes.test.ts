/**
 * Route reachability: every agent must be able to walk from its own desk to
 * each activity (coffee, foosball, sofa) and back without crossing furniture.
 *
 * These are the journeys the office actually performs, so a regression in the
 * obstacle table or a moved socket shows up here rather than on screen.
 */
import { describe, expect, it } from "vitest";
import {
  deskSocket,
  findPath,
  isWalkable,
  MAX_OFFICE_SEATS,
  OFFICE_DESK_SLOTS,
  OFFICE_POIS,
  segmentIsWalkable,
  type NavPoint,
} from "./office-navdata";

/**
 * Every leg of the polyline must stay clear of furniture.
 *
 * The first leg is skipped when the agent starts on a chair and the last when
 * it ends on one: standing up and sitting down deliberately cross the seat
 * volume. Everything between is aisle walking and must be clean.
 */
function legsAreClear(
  pts: NavPoint[],
  { skipFirstLeg = false, skipLastLeg = false } = {},
): boolean {
  const start = skipFirstLeg ? 1 : 0;
  const end = skipLastLeg ? pts.length - 2 : pts.length - 1;
  for (let i = start; i < end; i++) {
    if (!segmentIsWalkable(pts[i], pts[i + 1])) return false;
  }
  return true;
}

function pathLength(pts: NavPoint[]): number {
  let total = 0;
  for (let i = 1; i < pts.length; i++) {
    total += Math.hypot(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z);
  }
  return total;
}

const OFFICE_DIAGONAL = Math.hypot(13, 12);

describe("desk → activity routes", () => {
  const seats = Array.from({ length: MAX_OFFICE_SEATS }, (_, i) => i);

  it("gives all nine agents a reachable desk chair", () => {
    for (const seat of seats) {
      const socket = deskSocket(seat);
      expect(socket, `seat ${seat} has no socket`).not.toBeNull();
    }
  });

  it.each(OFFICE_POIS.map((p) => p.id))("routes every desk to the %s approach", (poiId) => {
    const poi = OFFICE_POIS.find((p) => p.id === poiId)!;
    const approach = poi.approach[0];
    expect(isWalkable(approach), `${poiId} approach is blocked`).toBe(true);

    for (const seat of seats) {
      const desk = OFFICE_DESK_SLOTS[seat];
      const path = findPath(desk, approach, { allowGoalInObstacle: false });
      expect(path.length, `seat ${seat} → ${poiId} produced no path`).toBeGreaterThan(1);
      // A path that never leaves the desk means A* gave up.
      const travelled = pathLength(path);
      expect(travelled, `seat ${seat} → ${poiId} path collapsed`).toBeGreaterThan(0.3);
      expect(travelled, `seat ${seat} → ${poiId} path absurdly long`).toBeLessThan(
        OFFICE_DIAGONAL * 3,
      );
      expect(
        legsAreClear(path, { skipFirstLeg: true }),
        `seat ${seat} → ${poiId} crosses furniture`,
      ).toBe(true);
    }
  });

  it("routes every agent back from each activity to its own desk", () => {
    for (const poi of OFFICE_POIS) {
      const approach = poi.approach[0];
      for (const seat of seats) {
        const desk = OFFICE_DESK_SLOTS[seat];
        const path = findPath(approach, desk, { allowGoalInObstacle: true });
        expect(path.length, `${poi.id} → seat ${seat} produced no path`).toBeGreaterThan(1);
        // Final leg lands on the chair, which is furniture by design.
        expect(
          legsAreClear(path, { skipLastLeg: true }),
          `${poi.id} → seat ${seat} crosses furniture`,
        ).toBe(true);
      }
    }
  });
});

describe("activity spots", () => {
  it("keeps every approach and queue slot walkable", () => {
    for (const poi of OFFICE_POIS) {
      for (const p of poi.approach) {
        expect(isWalkable(p), `${poi.id} approach blocked`).toBe(true);
      }
      for (const q of poi.queueSlots ?? []) {
        expect(isWalkable(q), `${poi.id} queue slot blocked`).toBe(true);
      }
    }
  });

  it("never assigns more slots than the POI can hold", () => {
    for (const poi of OFFICE_POIS) {
      expect(poi.slots.length).toBeLessThanOrEqual(poi.capacity);
    }
  });

  it("keeps slot ids unique across the whole office", () => {
    const ids = OFFICE_POIS.flatMap((p) => p.slots.map((s) => s.id));
    expect(new Set(ids).size, "duplicate slot id").toBe(ids.length);
  });

  it("connects the two foosball ends to each other", () => {
    const foos = OFFICE_POIS.find((p) => p.id === "foosball")!;
    const [a, b] = foos.slots.map((s) => s.position);
    const path = findPath(a, b);
    expect(path.length).toBeGreaterThan(1);
    expect(legsAreClear(path), "players cannot reach opposite ends").toBe(true);
  });
});
