import { describe, expect, it } from "vitest";
import {
  buildOfficeFloorMesh,
  createOfficeCrowd,
  crowdClosestPoint,
  crowdGoto,
  crowdSpeed,
  addCrowdAgent,
} from "./office-crowd";
import { FOOSBALL_TABLE_AABB, OFFICE_DESK_SLOTS, OFFICE_POIS } from "./office-navdata";

/**
 * centerOffset the live scene derives from the office GLB bounds, read off
 * `window.__mokaidOfficeDebug()`. Baking with it keeps these tests on the same
 * rasteriser grid phase as the running office — the floor mesh aligns to this
 * offset, so a different phase can hide (or invent) a split.
 */
const RUNTIME_CENTER_OFFSET = { x: -0.181, z: -0.232 };

describe("office-crowd", () => {
  it("builds a floor mesh with holes punched out of the furniture", () => {
    const { positions, indices } = buildOfficeFloorMesh({ x: 0, z: 0 });
    expect(positions.length).toBeGreaterThan(100);
    expect(indices.length).toBeGreaterThan(100);
    // No floor quad may sit inside a solid piece of furniture. The foosball
    // table is a good probe: it is small, central, and agents walk right past it.
    for (let i = 0; i < positions.length; i += 12) {
      const cx = (positions[i] + positions[i + 6]) / 2;
      const cz = (positions[i + 2] + positions[i + 8]) / 2;
      const inTable =
        cx >= FOOSBALL_TABLE_AABB.minX &&
        cx <= FOOSBALL_TABLE_AABB.maxX &&
        cz >= FOOSBALL_TABLE_AABB.minZ &&
        cz <= FOOSBALL_TABLE_AABB.maxZ;
      expect(inTable, `floor cell inside the foosball table at ${cx},${cz}`).toBe(false);
    }
  });

  /**
   * The floor mesh must stay one connected region. When OBSTACLE_PAD was 0.14
   * the 0.17 m corridor between the partition and the foosball table sealed
   * shut, splitting the office into two islands — agents assigned across the
   * divide walked into the pinch and looped in crowd-recover forever.
   */
  it("keeps the whole floor reachable as a single connected region", () => {
    const { positions } = buildOfficeFloorMesh(RUNTIME_CENTER_OFFSET);
    const STEP = 0.2;
    const cells = new Set<string>();
    // Each quad contributes 4 vertices (12 floats); v0 is its low corner.
    // The rasteriser starts at the polygon edge, which is not a multiple of
    // STEP, so index by rounded grid steps relative to the first quad rather
    // than by absolute position — otherwise neighbours land on the same key.
    let originX = Infinity;
    let originZ = Infinity;
    for (let i = 0; i < positions.length; i += 12) {
      originX = Math.min(originX, positions[i]);
      originZ = Math.min(originZ, positions[i + 2]);
    }
    for (let i = 0; i < positions.length; i += 12) {
      const gx = Math.round((positions[i] - originX) / STEP);
      const gz = Math.round((positions[i + 2] - originZ) / STEP);
      cells.add(`${gx},${gz}`);
    }
    expect(cells.size).toBeGreaterThan(500);

    // Flood fill from any cell; every cell must be reachable from it.
    const [seed] = cells;
    const seen = new Set([seed]);
    const stack = [seed];
    while (stack.length) {
      const [a, b] = stack.pop()!.split(",").map(Number);
      for (const [da, db] of [
        [1, 0],
        [-1, 0],
        [0, 1],
        [0, -1],
      ]) {
        const next = `${a + da},${b + db}`;
        if (cells.has(next) && !seen.has(next)) {
          seen.add(next);
          stack.push(next);
        }
      }
    }
    expect(seen.size, `${cells.size - seen.size} floor cells are cut off`).toBe(cells.size);
  });

  it("bakes a Recast navmesh and moves a crowd agent", async () => {
    const office = await createOfficeCrowd({ x: 0, z: 0 });
    expect(office).toBeTruthy();
    if (!office) return;

    const start = crowdClosestPoint(office.query, 0.4, -1.8);
    // Snap must stay near the requested aisle (no remote-island teleport).
    expect(Math.hypot(start.x - 0.4, start.z + 1.8)).toBeLessThan(1.0);

    const agent = addCrowdAgent(office.crowd, office.query, start.x, start.z);
    expect(agent).toBeTruthy();
    if (!agent) {
      office.destroy();
      return;
    }

    const dest = crowdClosestPoint(office.query, 2.2, 3.4); // s_coffee aisle
    expect(Math.hypot(dest.x - 2.2, dest.z - 3.4)).toBeLessThan(1.0);
    crowdGoto(agent, office.query, dest.x, dest.z);

    let moved = false;
    for (let i = 0; i < 180; i++) {
      office.crowd.update(1 / 30);
      if (crowdSpeed(agent) > 0.05) moved = true;
    }
    expect(moved).toBe(true);
    const p = agent.position();
    expect(Math.hypot(p.x - start.x, p.z - start.z)).toBeGreaterThan(0.5);

    office.destroy();
  }, 20_000);

  /**
   * The floor mesh being one region is necessary but not sufficient: Recast
   * erodes it again when baking, so aisles can survive the rasteriser and
   * still lose their navmesh polygons. This walks a real Detour agent between
   * the far corners of the office — the check that would have caught agents
   * stalling halfway to the foosball table.
   */
  it("walks an agent between opposite wings of the office", async () => {
    // The scene centres the GLB on its own bounds, so the floor rasteriser is
    // phase-shifted by this offset at runtime. Baking at {0,0} samples a
    // different grid phase and can hide a split that the real office has.
    const office = await createOfficeCrowd(RUNTIME_CENTER_OFFSET);
    expect(office).toBeTruthy();
    if (!office) return;

    const centred = (p: { x: number; z: number }) => ({
      x: p.x - RUNTIME_CENTER_OFFSET.x,
      z: p.z - RUNTIME_CENTER_OFFSET.z,
    });
    const foosball = OFFICE_POIS.find((p) => p.id === "foosball")!.approach[0];
    const journeys: Array<[string, { x: number; z: number }, { x: number; z: number }]> = [
      ["west desk → foosball", centred(OFFICE_DESK_SLOTS[0]), centred(foosball)],
      ["west desk → east desk", centred(OFFICE_DESK_SLOTS[0]), centred(OFFICE_DESK_SLOTS[6])],
      ["lounge → foosball", centred({ x: -5.4, z: 3.2 }), centred(foosball)],
    ];

    const stalled: string[] = [];
    for (const [label, from, to] of journeys) {
      const start = crowdClosestPoint(office.query, from.x, from.z);
      const agent = addCrowdAgent(office.crowd, office.query, start.x, start.z);
      if (!agent) {
        stalled.push(`${label}: could not spawn agent`);
        continue;
      }
      const dest = crowdClosestPoint(office.query, to.x, to.z);
      crowdGoto(agent, office.query, dest.x, dest.z);
      // 50 s of simulated walking is far more than any cross-office trip.
      for (let i = 0; i < 1500; i++) office.crowd.update(1 / 30);
      const end = agent.position();
      const left = Math.hypot(end.x - dest.x, end.z - dest.z);
      if (left > 0.6) stalled.push(`${label}: stopped ${left.toFixed(2)}m short`);
      office.crowd.removeAgent(agent);
    }

    office.destroy();
    expect(stalled, `agents never arrived:\n  ${stalled.join("\n  ")}`).toEqual([]);
  }, 40_000);

  /**
   * Recast erodes the floor mesh by the agent radius, so a point can be
   * walkable for the A* grid yet carry no navmesh polygon. Detour then never
   * delivers the agent, which showed up in the office as a player stuck in a
   * permanent walk/recover loop a few metres short of the foosball table.
   * Every place we actively send an agent must survive that erosion.
   */
  it("puts every POI spot and desk on the baked navmesh", async () => {
    const office = await createOfficeCrowd({ x: 0, z: 0 });
    expect(office).toBeTruthy();
    if (!office) return;

    /** Detour can nudge a target onto the nearest polygon; beyond this it is a different place. */
    const MAX_OFF_MESH = 0.35;
    const offMesh: string[] = [];

    const check = (label: string, x: number, z: number) => {
      const snap = crowdClosestPoint(office.query, x, z);
      const d = Math.hypot(snap.x - x, snap.z - z);
      if (d > MAX_OFF_MESH) offMesh.push(`${label} (${x.toFixed(2)}, ${z.toFixed(2)}) off by ${d.toFixed(2)}m`);
    };

    for (const poi of OFFICE_POIS) {
      for (const slot of poi.slots) {
        // Sitting spots are on the cushion — furniture, and off-mesh by
        // design. The agent walks to the approach and the seat blend covers
        // the last step, so only standing spots must be Detour-reachable.
        if (slot.animation === "sitting_sofa") continue;
        check(`${poi.id}/${slot.id}`, slot.position.x, slot.position.z);
      }
      for (const [i, a] of poi.approach.entries()) check(`${poi.id}/approach${i}`, a.x, a.z);
      for (const [i, q] of (poi.queueSlots ?? []).entries()) check(`${poi.id}/queue${i}`, q.x, q.z);
    }
    // Desks sit inside furniture by design; the agent walks to the chair's
    // edge, so only assert the desk is not stranded far from any polygon.
    for (const [i, desk] of OFFICE_DESK_SLOTS.entries()) {
      const snap = crowdClosestPoint(office.query, desk.x, desk.z);
      const d = Math.hypot(snap.x - desk.x, snap.z - desk.z);
      if (d > 1.2) offMesh.push(`desk${i} (${desk.x}, ${desk.z}) off by ${d.toFixed(2)}m`);
    }

    office.destroy();
    expect(offMesh, `unreachable targets:\n  ${offMesh.join("\n  ")}`).toEqual([]);
  }, 30_000);
});
