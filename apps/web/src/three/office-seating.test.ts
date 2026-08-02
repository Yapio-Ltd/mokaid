/**
 * Seating / POI geometry invariants.
 *
 * Every expectation here is derived from measured office.glb geometry
 * (up-facing triangle bands + rod-side vertex counts), not from eyeballing:
 *   - Cube.021 main sofa  cushion band Y = 0.66 (1.15 m² up-facing)
 *   - Cube.024 sofa back  occupies Z −6.29..−5.74, Y 0.70..1.16
 *   - Object_122 chairs   cushion band Y = 0.51
 *   - soccer table.001    top Y = 0.64, rods protrude on ±X (924 verts each
 *                         side vs 78/208 on ±Z) → players stand east/west
 */
import { describe, expect, it } from "vitest";
import {
  FOOSBALL_TABLE_AABB,
  isWalkable,
  OFFICE_DESK_SLOTS,
  OFFICE_OBSTACLES,
  OFFICE_POIS,
  pointHitsObstacle,
  poiSlotSocket,
  type NavPoint,
} from "./office-navdata";

/** Cube.024 — the sofa backrest an agent must never be placed inside. */
const SOFA_BACKREST = { minX: 1.44, maxX: 2.14, minZ: -6.29, maxZ: -5.74 };
/** Cube.021 — main sofa body; cushion top measured at Y 0.66. */
const SOFA_CUSHION_Y = 0.66;
/** Object_122 desk chairs; cushion top measured at Y 0.51. */
const DESK_CUSHION_Y = 0.51;

function inAabb(p: NavPoint, b: typeof SOFA_BACKREST): boolean {
  return p.x >= b.minX && p.x <= b.maxX && p.z >= b.minZ && p.z <= b.maxZ;
}

describe("sofa seating", () => {
  const sofa = OFFICE_POIS.find((p) => p.id === "sofa_main")!;

  it("never places a sitter inside the backrest volume", () => {
    for (const slot of sofa.slots) {
      expect(inAabb(slot.position, SOFA_BACKREST), `${slot.id} is inside Cube.024 backrest`).toBe(
        false,
      );
    }
  });

  it("uses the measured cushion height so agents rest on the sofa, not in it", () => {
    for (const slot of sofa.slots) {
      expect(slot.seatHeight, `${slot.id} seatHeight`).toBeCloseTo(SOFA_CUSHION_Y, 2);
    }
  });

  it("spreads sitters across the cushion without overlapping bodies", () => {
    const xs = sofa.slots.map((s) => s.position.x).sort((a, b) => a - b);
    for (let i = 1; i < xs.length; i++) {
      expect(xs[i] - xs[i - 1], "sitters too close together").toBeGreaterThanOrEqual(0.45);
    }
  });
});

describe("foosball players", () => {
  const foos = OFFICE_POIS.find((p) => p.id === "foosball")!;
  const midX = (FOOSBALL_TABLE_AABB.minX + FOOSBALL_TABLE_AABB.maxX) / 2;
  const midZ = (FOOSBALL_TABLE_AABB.minZ + FOOSBALL_TABLE_AABB.maxZ) / 2;

  /** Shortest distance from a point to the table's footprint. */
  function gapToTable(p: { x: number; z: number }): number {
    const dx = Math.max(FOOSBALL_TABLE_AABB.minX - p.x, 0, p.x - FOOSBALL_TABLE_AABB.maxX);
    const dz = Math.max(FOOSBALL_TABLE_AABB.minZ - p.z, 0, p.z - FOOSBALL_TABLE_AABB.maxZ);
    return Math.hypot(dx, dz);
  }

  it("puts the two players on different sides of the table", () => {
    const [a, b] = foos.slots;
    const sameSide =
      Math.abs(a.position.x - b.position.x) < 0.3 && Math.abs(a.position.z - b.position.z) < 0.3;
    expect(sameSide, "both players on the same spot").toBe(false);
  });

  it("keeps each player within arm's reach of the table", () => {
    for (const slot of foos.slots) {
      const gap = gapToTable(slot.position);
      expect(gap, `${slot.id} standing inside the table`).toBeGreaterThan(0);
      expect(gap, `${slot.id} too far to reach the handles`).toBeLessThan(0.55);
    }
  });

  it("faces each player toward the table", () => {
    for (const slot of foos.slots) {
      // facing is a Babylon Y rotation where 0 looks down +Z.
      const look = { x: Math.sin(slot.facing), z: Math.cos(slot.facing) };
      const toTable = { x: midX - slot.position.x, z: midZ - slot.position.z };
      const len = Math.hypot(toTable.x, toTable.z);
      // Dot product > 0.7 ≈ within 45° of looking straight at the table.
      const dot = (look.x * toTable.x + look.z * toTable.z) / (len || 1);
      expect(dot, `${slot.id} does not face the table`).toBeGreaterThan(0.7);
    }
  });

  it("keeps both player spots walkable and outside the table body", () => {
    for (const slot of foos.slots) {
      expect(pointHitsObstacle(slot.position), `${slot.id} inside furniture`).toBe(false);
      expect(isWalkable(slot.position), `${slot.id} not reachable`).toBe(true);
    }
  });

  it("seats two players so a duo can actually play", () => {
    expect(foos.capacity).toBe(2);
    expect(foos.slots).toHaveLength(2);
  });
});

describe("desk chairs", () => {
  it("uses the measured chair cushion height for every seat", () => {
    for (const [i, desk] of OFFICE_DESK_SLOTS.entries()) {
      expect(desk.seatHeight, `desk ${i} seatHeight`).toBeCloseTo(DESK_CUSHION_Y, 2);
    }
  });

  it("gives each of the nine agents a distinct chair", () => {
    const sockets = OFFICE_DESK_SLOTS.map((_, i) => poiSocketOrDesk(i));
    expect(new Set(sockets).size).toBe(OFFICE_DESK_SLOTS.length);
  });
});

function poiSocketOrDesk(i: number): string {
  return `${OFFICE_DESK_SLOTS[i].x.toFixed(3)},${OFFICE_DESK_SLOTS[i].z.toFixed(3)}`;
}

describe("coffee machine", () => {
  const coffee = OFFICE_POIS.find((p) => p.id === "coffee")!;

  it("stands the agent in front of the kitchenette, not inside it", () => {
    for (const slot of coffee.slots) {
      expect(pointHitsObstacle(slot.position), `${slot.id} inside kitchenette`).toBe(false);
      expect(isWalkable(slot.position), `${slot.id} unreachable`).toBe(true);
    }
  });
});

describe("socket exposure", () => {
  it("returns a usable socket for every POI slot", () => {
    for (const poi of OFFICE_POIS) {
      for (const slot of poi.slots) {
        const socket = poiSlotSocket(slot.id);
        expect(socket, `${slot.id} has no socket`).not.toBeNull();
        expect(socket!.sits).toBe(slot.animation === "sitting_sofa");
      }
    }
  });

  it("keeps every declared obstacle non-degenerate", () => {
    for (const o of OFFICE_OBSTACLES) {
      expect(o.maxX).toBeGreaterThan(o.minX);
      expect(o.maxZ).toBeGreaterThan(o.minZ);
    }
  });
});
