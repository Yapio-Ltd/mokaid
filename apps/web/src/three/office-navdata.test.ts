/**
 * Navigation invariants: agents must never cross furniture, walls, chairs,
 * lamps or planters. Obstacles are generated from office.blend; paths run on
 * the occupancy grid.
 */
import { describe, expect, it } from "vitest";
import {
  AGENT_RADIUS,
  deskSocket,
  distToAabbEdge,
  findPath,
  FOOSBALL_STAND_GAP,
  FOOSBALL_TABLE_AABB,
  isWalkable,
  NAV_CLEARANCE,
  NAV_OBSTACLES,
  OFFICE_DESK_SLOTS,
  OFFICE_NAV_NODES,
  OFFICE_OBSTACLES,
  OFFICE_POIS,
  poiSlotSocket,
  pointHitsObstacle,
  resolveCollision,
  segmentIsWalkable,
} from "./office-navdata";
import {
  cachedDeskToPoi,
  cachedPoiToDesk,
  OFFICE_PATHS,
  pathForSeat,
} from "./office-paths";

/** Every consecutive pair of a polyline must be clear of obstacles. */
function pathIsClear(pts: { x: number; z: number }[], skipLastLeg = false): boolean {
  const end = skipLastLeg ? pts.length - 2 : pts.length - 1;
  for (let i = 0; i < end; i++) {
    if (!segmentIsWalkable(pts[i], pts[i + 1])) return false;
  }
  return true;
}

describe("office-navdata", () => {
  it("aligns planning clearance with agent body radius", () => {
    expect(NAV_CLEARANCE).toBe(AGENT_RADIUS);
    expect(NAV_OBSTACLES.length).toBeGreaterThan(40);
  });

  it("exposes nine unique desk seats", () => {
    expect(OFFICE_DESK_SLOTS).toHaveLength(9);
    const keys = new Set(OFFICE_DESK_SLOTS.map((s) => `${s.x.toFixed(3)},${s.z.toFixed(3)}`));
    expect(keys.size).toBe(9);
  });

  it("keeps every aisle anchor walkable", () => {
    for (const n of OFFICE_NAV_NODES) {
      expect(isWalkable(n), `anchor ${n.id} blocked`).toBe(true);
    }
  });

  it("covers the full furniture inventory (walls, desks, chairs, planters…)", () => {
    expect(OFFICE_OBSTACLES.length).toBeGreaterThan(50);
    // Walls with openings are split, not one giant box.
    const giant = OFFICE_OBSTACLES.filter(
      (o) => (o.maxX - o.minX) * (o.maxZ - o.minZ) > 20,
    );
    expect(giant).toHaveLength(0);
  });

  it("reaches every desk seat from the coffee corner without crossing furniture", () => {
    const from = { x: 1.99, z: -5.08 };
    for (const [i, seat] of OFFICE_DESK_SLOTS.entries()) {
      const path = findPath(from, seat, { allowGoalInObstacle: true });
      expect(path.length, `desk ${i} unreachable`).toBeGreaterThan(1);
      // Whole path minus the final in-desk snap must be clear.
      expect(pathIsClear(path, true), `desk ${i} path crosses furniture`).toBe(true);
      expect(path[path.length - 1].x).toBeCloseTo(seat.x, 3);
      expect(path[path.length - 1].z).toBeCloseTo(seat.z, 3);
    }
  });

  it("reaches every POI slot from every desk", () => {
    for (const [i, seat] of OFFICE_DESK_SLOTS.entries()) {
      for (const poi of OFFICE_POIS) {
        for (const slot of poi.slots) {
          const allow = slot.animation === "sitting_sofa";
          const path = findPath(seat, slot.position, { allowGoalInObstacle: allow });
          expect(path.length, `desk ${i} -> ${slot.id} unreachable`).toBeGreaterThan(1);
          // Skip first leg (leaving the desk) and last leg when sitting.
          const inner = path.slice(1);
          expect(
            pathIsClear(inner, allow),
            `desk ${i} -> ${slot.id} crosses furniture`,
          ).toBe(true);
        }
      }
    }
  });

  it("keeps foosball & coffee stand-points walkable, sofa seats inside cushions", () => {
    const foos = OFFICE_POIS.find((p) => p.kind === "foosball")!;
    for (const slot of foos.slots) {
      expect(isWalkable(slot.position), `${slot.id} not walkable`).toBe(true);
    }
    const coffee = OFFICE_POIS.find((p) => p.kind === "coffee")!;
    expect(isWalkable(coffee.slots[0].position)).toBe(true);
    const sofa = OFFICE_POIS.find((p) => p.kind === "sofa")!;
    for (const slot of sofa.slots) {
      expect(pointHitsObstacle(slot.position), `${slot.id} should be on cushion`).toBe(true);
    }
    for (const poi of OFFICE_POIS) {
      for (const a of poi.approach) {
        expect(isWalkable(a), `approach of ${poi.id} blocked`).toBe(true);
      }
      for (const q of poi.queueSlots ?? []) {
        expect(isWalkable(q), `queue of ${poi.id} blocked`).toBe(true);
      }
    }
  });

  it("separates the two foosball players by the table (no straight line through)", () => {
    const foos = OFFICE_POIS.find((p) => p.kind === "foosball")!;
    expect(segmentIsWalkable(foos.slots[0].position, foos.slots[1].position)).toBe(false);
  });

  it("exposes at least nine exclusive patrol loops", () => {
    expect(OFFICE_PATHS.length).toBeGreaterThanOrEqual(9);
    const ids = new Set(OFFICE_PATHS.map((p) => p.id));
    expect(ids.size).toBe(OFFICE_PATHS.length);
    for (let i = 0; i < 9; i++) {
      expect(pathForSeat(i).id).toBe(OFFICE_PATHS[i % OFFICE_PATHS.length].id);
    }
  });

  it("keeps every patrol waypoint and segment obstacle-free", () => {
    for (const path of OFFICE_PATHS) {
      expect(path.waypoints.length).toBeGreaterThan(2);
      for (const wp of path.waypoints) {
        expect(isWalkable(wp), `${path.id} waypoint blocked`).toBe(true);
      }
      const pts = path.loop ? [...path.waypoints, path.waypoints[0]] : path.waypoints;
      for (let i = 0; i < pts.length - 1; i++) {
        expect(
          segmentIsWalkable(pts[i], pts[i + 1]),
          `${path.id} leg ${i} crosses furniture`,
        ).toBe(true);
      }
    }
  });

  it("precomputes clear desk↔POI routes for every seat and slot", () => {
    for (let d = 0; d < OFFICE_DESK_SLOTS.length; d++) {
      for (const poi of OFFICE_POIS) {
        for (const slot of poi.slots) {
          const outbound = cachedDeskToPoi(d, slot.id);
          expect(outbound, `missing cache desk ${d} -> ${slot.id}`).toBeTruthy();
          expect(outbound!.points.length).toBeGreaterThan(1);
          expect(pathIsClear(outbound!.points.slice(1), outbound!.allowGoalInObstacle)).toBe(true);

          const inbound = cachedPoiToDesk(slot.id, d);
          expect(inbound, `missing cache ${slot.id} -> desk ${d}`).toBeTruthy();
          expect(inbound!.points.length).toBeGreaterThan(1);
          // Leaving a sofa seat starts inside furniture; desk snap may end inside.
          const fromSit = slot.animation === "sitting_sofa";
          const inner = fromSit ? inbound!.points.slice(1) : inbound!.points;
          expect(pathIsClear(inner, true)).toBe(true);
        }
      }
    }
  });

  it("never returns a path crossing furniture even for blocked goals", () => {
    const insideMeetingTable = { x: -5.7, z: 3.9 };
    expect(pointHitsObstacle(insideMeetingTable)).toBe(true);
    const path = findPath({ x: 0.35, z: -1.6 }, insideMeetingTable);
    // Goal is dropped (not allowGoalInObstacle) and the rest stays clear.
    expect(pathIsClear(path)).toBe(true);
  });

  it("resolveCollision slides a point out of any obstacle (raw + clearance)", () => {
    for (const probe of [
      { x: -5.7, z: 3.9 }, // meeting table (table 2)
      { x: -1.8, z: 4.7 }, // foosball table
      { x: -5.7, z: 0.2 }, // desk Cube.011
      { x: -1.79, z: -6.0 }, // main sofa
    ]) {
      expect(pointHitsObstacle(probe)).toBe(true);
      const out = resolveCollision(probe);
      expect(pointHitsObstacle(out)).toBe(false);
      expect(isWalkable(out), `resolved ${JSON.stringify(probe)} not walkable`).toBe(true);
    }
  });

  it("keeps the meeting-room table solid so agents route around it", () => {
    // table 2 sits at X[-6.17,-5.24] Z[3.06,4.72] in the west corner.
    expect(pointHitsObstacle({ x: -5.7, z: 3.9 })).toBe(true);
    expect(isWalkable({ x: -5.7, z: 3.9 })).toBe(false);
    const freed = resolveCollision({ x: -5.7, z: 3.9 });
    expect(isWalkable(freed)).toBe(true);
  });

  it("defines foosball, sofa and coffee POIs with capacity", () => {
    expect(OFFICE_POIS.find((p) => p.kind === "foosball")?.capacity).toBe(2);
    expect(OFFICE_POIS.find((p) => p.kind === "sofa")?.capacity).toBe(3);
    expect(OFFICE_POIS.find((p) => p.kind === "coffee")?.capacity).toBe(1);
  });

  it("exposes seat sockets for desks, sofa and foosball", () => {
    for (let i = 0; i < OFFICE_DESK_SLOTS.length; i++) {
      const sock = deskSocket(i);
      expect(sock, `desk ${i}`).toBeTruthy();
      expect(sock!.sits).toBe(true);
      expect(sock!.kind).toBe("desk");
      expect(sock!.seatHeight).toBeGreaterThan(0);
      // Path can terminate at the desk seat (allowGoalInObstacle).
      const path = findPath({ x: -1.99, z: -4.7 }, sock!.position, { allowGoalInObstacle: true });
      expect(path.length, `desk ${i} unreachable`).toBeGreaterThan(1);
    }

    const sofa = poiSlotSocket("sofa_b");
    expect(sofa?.sits).toBe(true);
    expect(pointHitsObstacle(sofa!.position)).toBe(true);

    for (const id of ["foosball_a", "foosball_b"] as const) {
      const sock = poiSlotSocket(id);
      expect(sock, id).toBeTruthy();
      expect(sock!.sits).toBe(false);
      expect(isWalkable(sock!.position), `${id} not walkable`).toBe(true);
      const edge = distToAabbEdge(sock!.position, FOOSBALL_TABLE_AABB);
      expect(edge, `${id} too far from table`).toBeLessThanOrEqual(FOOSBALL_STAND_GAP + 0.05);
      expect(edge, `${id} inside table`).toBeGreaterThan(0.05);
    }

    // Players face the table from whichever flanks the navmesh actually
    // reaches, so assert the intent (looking at the table) rather than fixed
    // angles that break whenever a spot moves.
    const midX = (FOOSBALL_TABLE_AABB.minX + FOOSBALL_TABLE_AABB.maxX) / 2;
    const midZ = (FOOSBALL_TABLE_AABB.minZ + FOOSBALL_TABLE_AABB.maxZ) / 2;
    for (const id of ["foosball_a", "foosball_b"] as const) {
      const sock = poiSlotSocket(id)!;
      const look = { x: Math.sin(sock.facing), z: Math.cos(sock.facing) };
      const to = { x: midX - sock.position.x, z: midZ - sock.position.z };
      const len = Math.hypot(to.x, to.z) || 1;
      expect((look.x * to.x + look.z * to.z) / len, `${id} faces away`).toBeGreaterThan(0.7);
    }
  });
});
