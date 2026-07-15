/**
 * Unit tests for office navigation graph / walkability invariants.
 */
import { describe, expect, it } from "vitest";
import {
  findPath,
  isWalkable,
  OFFICE_DESK_SLOTS,
  OFFICE_NAV_EDGES,
  OFFICE_NAV_NODES,
  OFFICE_POIS,
  pointHitsObstacle,
  segmentIsWalkable,
} from "./office-navdata";

describe("office-navdata", () => {
  it("exposes nine unique desk seats", () => {
    expect(OFFICE_DESK_SLOTS).toHaveLength(9);
    const keys = new Set(OFFICE_DESK_SLOTS.map((s) => `${s.x.toFixed(3)},${s.z.toFixed(3)}`));
    expect(keys.size).toBe(9);
  });

  it("keeps every nav node connected by at least one edge", () => {
    const connected = new Set<string>();
    for (const e of OFFICE_NAV_EDGES) {
      connected.add(e.from);
      connected.add(e.to);
    }
    for (const n of OFFICE_NAV_NODES) {
      expect(connected.has(n.id)).toBe(true);
    }
  });

  it("finds a path between opposite aisles", () => {
    const path = findPath({ x: -5.6, z: -5.2 }, { x: 5.5, z: -0.4 });
    expect(path.length).toBeGreaterThan(2);
  });

  it("rejects points inside obstacle AABBs", () => {
    expect(pointHitsObstacle({ x: -5.0, z: 0 })).toBe(true);
    expect(isWalkable({ x: -5.6, z: -5.2 })).toBe(true);
  });

  it("keeps aisle graph coherent for pathfinding", () => {
    const path = findPath({ x: -5.6, z: -5.2 }, { x: 4.6, z: 2.6 });
    expect(path.length).toBeGreaterThan(3);
    const back = findPath({ x: -5.4, z: 3.2 }, { x: 5.5, z: -0.4 });
    expect(back.length).toBeGreaterThan(3);
    // Sampled obstacle test still works for hard interiors.
    expect(pointHitsObstacle({ x: -5.0, z: 0 })).toBe(true);
    expect(segmentIsWalkable({ x: -5.6, z: -5.2 }, { x: -0.5, z: -5.2 })).toBe(true);
  });

  it("defines foosball, sofa and coffee POIs with capacity", () => {
    expect(OFFICE_POIS.find((p) => p.kind === "foosball")?.capacity).toBe(2);
    expect(OFFICE_POIS.find((p) => p.kind === "sofa")?.capacity).toBe(3);
    expect(OFFICE_POIS.find((p) => p.kind === "coffee")?.capacity).toBe(1);
  });
});
