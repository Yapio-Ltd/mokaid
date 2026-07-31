/**
 * Office navigation data (raw GLB / Blender-local Y-up space).
 *
 * Obstacles are generated from office.blend via
 * `blender --background office.blend --python scripts/dump_blender_obstacles.py`
 * then `python3 scripts/gen_office_obstacles.py` (walls rasterized into
 * segments so door openings stay walkable).
 *
 * Pathfinding: A* over a 0.15 m occupancy grid built from the obstacle list,
 * inflated by NAV_CLEARANCE. Paths are then smoothed with line-of-sight
 * shortcuts. This guarantees agents never cross furniture or walls.
 */

export interface NavPoint {
  x: number;
  z: number;
}

export interface NavNode extends NavPoint {
  id: string;
}

export interface Aabb2 {
  minX: number;
  maxX: number;
  minZ: number;
  maxZ: number;
}

export type OfficePoiKind = "foosball" | "sofa" | "coffee";

export type SecondaryActivity =
  | "walking"
  | "preparing_coffee"
  | "playing_foosball"
  | "sitting_sofa"
  | "scrolling"
  | "stretching"
  | "looking_around"
  | null;

export interface OfficePoiSlot {
  id: string;
  position: NavPoint;
  /** Radians, Babylon Y rotation (0 faces +Z). */
  facing: number;
  animation: SecondaryActivity;
  /**
   * Cushion top Y in raw office-GLB space (before centering).
   * Scene placement: `seatHeight - centerOffset.y - sitPelvisHeight`.
   */
  seatHeight?: number;
}

export interface OfficePoi {
  id: string;
  kind: OfficePoiKind;
  capacity: number;
  slots: OfficePoiSlot[];
  /** Approach points in aisle space before locking a slot. */
  approach: NavPoint[];
  /** Optional queue positions when all slots are taken. */
  queueSlots?: NavPoint[];
}

export interface FindPathOptions {
  /** Allow the final point inside an obstacle (sofa / desk seat snap). */
  allowGoalInObstacle?: boolean;
}

/** Agent collision radius (agent-agent separation & visuals). */
export const AGENT_RADIUS = 0.35;

/** Clearance between an agent's center and any obstacle while walking (= body radius). */
export const NAV_CLEARANCE = AGENT_RADIUS;

/** Max agents that share the 3D office (one desk each). */
export const MAX_OFFICE_SEATS = 9;

/**
 * Desk chair seats in raw GLB space (before centering).
 * Index 0..8 maps 1:1 to agent.seat_index. Positions are Object_122 chair
 * instances; `facing` looks toward the desk; paths snap with allowGoalInObstacle.
 */
export interface DeskSeat extends NavPoint {
  /** Radians, Babylon Y rotation (0 faces +Z). */
  facing: number;
  /** Chair cushion top Y in raw office-GLB space. */
  seatHeight: number;
}

export const OFFICE_DESK_SLOTS: DeskSeat[] = [
  { x: -5.163, z: 1.445, facing: -3.1328, seatHeight: 0.5 },
  { x: -5.157, z: -2.781, facing: -0.0154, seatHeight: 0.5 },
  { x: -1.682, z: -4.243, facing: 0.0012, seatHeight: 0.5 },
  { x: -1.75, z: -0.52, facing: -1.7199, seatHeight: 0.5 },
  { x: 1.986, z: -3.414, facing: 0.0773, seatHeight: 0.5 },
  { x: 0.854, z: 1.075, facing: 3.0804, seatHeight: 0.5 },
  { x: 5.006, z: 0.13, facing: 1.5148, seatHeight: 0.5 },
  { x: 0.287, z: 4.155, facing: -3.1385, seatHeight: 0.5 },
  { x: -2.158, z: 3.19, facing: -2.2662, seatHeight: 0.5 },
];

/** Approximate flat floor height (Y) once the GLB is planted at y=0. */
export const OFFICE_FLOOR_Y = 0;

/**
 * Exterior walkable polygon (office footprint, counterclockwise).
 */
export const OFFICE_WALKABLE_POLYGON: NavPoint[] = [
  { x: -6.4, z: -6.4 },
  { x: 6.6, z: -6.4 },
  { x: 6.8, z: 5.6 },
  { x: -6.2, z: 5.6 },
];

/**
 * Physical furniture / wall AABBs (raw mesh bounds, NOT inflated —
 * walkability adds NAV_CLEARANCE). Generated from office.blend; walls with
 * openings are split into segments ("#g" suffixes).
 */
export const OFFICE_OBSTACLES: Aabb2[] = [
  { minX: -7.15, maxX: 7.45, minZ: -6.55, maxZ: -6.45 }, // Plane.005#g0 north wall
  { minX: -6.49, maxX: -4.46, minZ: -6.38, maxZ: -5.74 }, // Cube.012 back-left sofa
  { minX: -6.36, maxX: -4.8, minZ: -4.79, maxZ: -4.4 }, // Plane.036 lounge table
  { minX: -6.14, maxX: -4.2, minZ: -2.46, maxZ: -1.54 }, // Cube.001 desk1
  { minX: -6.02, maxX: -4.32, minZ: 0.3, maxZ: 1.22 }, // Cube.003 desk0
  { minX: -5.51, maxX: -4.82, minZ: 1.12, maxZ: 1.77 }, // Object_122 chair
  { minX: -5.5, maxX: -4.81, minZ: -3.11, maxZ: -2.45 }, // Object_122.003 chair
  { minX: -4.89, maxX: -3.64, minZ: -6.94, maxZ: -5.53 }, // model_4 shelving
  { minX: -4.85, maxX: -3.94, minZ: 2.78, maxZ: 3.79 }, // model_2.007 armchair
  { minX: -4.38, maxX: -3.76, minZ: 1.97, maxZ: 2.66 }, // model_2.008 armchair
  { minX: -4.32, maxX: -3.34, minZ: 2.09, maxZ: 2.58 }, // Cube.017 side table
  { minX: -4.08, maxX: -3.55, minZ: -6.46, maxZ: -5.89 }, // Plane.004 plant
  { minX: -4.08, maxX: -3.17, minZ: 1.79, maxZ: 2.79 }, // model_2.005 armchair
  { minX: -3.58, maxX: -2.92, minZ: -0.89, maxZ: -0.19 }, // Object_122.002 chair
  { minX: -3.27, maxX: -1.0, minZ: 2.08, maxZ: 3.0 }, // Cube.008 desk8
  { minX: -3.25, maxX: -0.73, minZ: -6.44, maxZ: -5.65 }, // Cube.002 kitchenette
  { minX: -2.93, maxX: -1.01, minZ: 0.79, maxZ: 1.32 }, // Cube.037 low cabinet
  { minX: -2.9, maxX: -1.98, minZ: -1.51, maxZ: 0.2 }, // Cube.004 desk3
  { minX: -2.65, maxX: -0.71, minZ: -3.88, maxZ: -2.96 }, // Cube desk2
  { minX: -2.5, maxX: -1.81, minZ: 2.86, maxZ: 3.52 }, // Object_122.004 chair
  { minX: -2.08, maxX: -1.42, minZ: -0.87, maxZ: -0.17 }, // Object_122.001 chair
  { minX: -1.65, maxX: -0.95, minZ: -2.96, maxZ: -2.26 }, // Object_122.006 chair
  { minX: -1.34, maxX: -1.09, minZ: 1.32, maxZ: 1.57 }, // Sphere décor
  { minX: -1.05, maxX: -0.75, minZ: 2.05, maxZ: 2.85 }, // wall 1#g0 partition W
  { minX: -1.05, maxX: -0.75, minZ: 3.05, maxZ: 4.35 }, // wall 1#g2 partition W
  { minX: -1.05, maxX: 1.25, minZ: 2.85, maxZ: 3.05 }, // wall 1#g1 partition S
  { minX: -0.96, maxX: -0.11, minZ: -1.42, maxZ: -0.57 }, // model_2.009 armchair
  { minX: -0.87, maxX: 0.04, minZ: 5.4, maxZ: 6.41 }, // model_2.006 armchair N
  { minX: -0.85, maxX: 0.06, minZ: -6.55, maxZ: -5.54 }, // model_2 armchair
  { minX: -0.59, maxX: 1.07, minZ: 2.97, maxZ: 3.89 }, // Cube.007 desk7
  { minX: -0.2, maxX: 0.61, minZ: 4.03, maxZ: 4.85 }, // Object_122.005 chair desk7
  { minX: 0.0, maxX: 0.07, minZ: -6.47, maxZ: -4.45 }, // Plane.006 divider wall
  { minX: 0.18, maxX: 1.06, minZ: 5.59, maxZ: 6.24 }, // Cube.060 planter N
  { minX: 0.25, maxX: 0.29, minZ: -6.35, maxZ: -5.68 }, // Cube.023 lamp
  { minX: 0.51, maxX: 1.17, minZ: -0.87, maxZ: -0.17 }, // Object_122.007 chair
  { minX: 0.92, maxX: 2.66, minZ: -6.35, maxZ: -5.64 }, // Cube.021 main sofa
  { minX: 1.05, maxX: 1.25, minZ: 3.05, maxZ: 4.95 }, // wall 1#g3 partition E
  { minX: -0.07, maxX: 1.87, minZ: -0.12, maxZ: 0.8 }, // Cube.006 desk5
  { minX: 1.06, maxX: 3.0, minZ: -3.28, maxZ: -2.36 }, // Cube.005 desk4
  { minX: 1.42, maxX: 2.27, minZ: 4.13, maxZ: 5.21 }, // soccer table.001 foosball
  { minX: 1.44, maxX: 2.14, minZ: -6.29, maxZ: -5.74 }, // Cube.024 sofa back
  { minX: 2.16, maxX: 2.92, minZ: -2.29, maxZ: -1.59 }, // Object_122.008 chair
  { minX: 2.93, maxX: 3.4, minZ: -6.47, maxZ: -6.08 }, // Plane.046 shelf
  { minX: 3.3, maxX: 4.13, minZ: 2.19, maxZ: 3.05 }, // Cube.083? chair meeting W
  { minX: 3.61, maxX: 4.42, minZ: -6.45, maxZ: -5.81 }, // Mirror
  { minX: 3.69, maxX: 4.25, minZ: -6.13, maxZ: -5.95 }, // Circle.008/009 décor
  { minX: 3.98, maxX: 4.89, minZ: 2.41, maxZ: 3.42 }, // model_2.003 armchair
  { minX: 4.26, maxX: 4.96, minZ: 3.21, maxZ: 3.89 }, // photocopy machine.001
  { minX: 4.28, maxX: 4.78, minZ: 2.65, maxZ: 3.14 }, // Cube.018 side table
  { minX: 4.39, maxX: 7.38, minZ: -1.82, maxZ: -1.76 }, // Plane.014 room wall (door W)
  { minX: 4.68, maxX: 5.33, minZ: -0.22, maxZ: 0.48 }, // Object_122.010 chair desk6
  { minX: 5.12, maxX: 7.14, minZ: -6.48, maxZ: -5.8 }, // Rack
  { minX: 5.24, maxX: 6.17, minZ: 3.06, maxZ: 4.72 }, // table 2 meeting
  { minX: 5.26, maxX: 6.18, minZ: -0.8, maxZ: 1.14 }, // Cube.011 desk6
  { minX: 5.46, maxX: 5.95, minZ: 3.18, maxZ: 3.67 }, // model_0.005 chair meeting
  { minX: 6.39, maxX: 7.38, minZ: 2.32, maxZ: 2.38 }, // Plane.023 meeting wall S
  { minX: 6.43, maxX: 7.34, minZ: -5.92, maxZ: -4.92 }, // model_2.001 armchair NE
  { minX: 6.64, maxX: 7.17, minZ: -5.68, maxZ: -5.14 }, // model_0.001 side table NE
];

/** Inset applied to chair-like AABBs so agent-radius clearance still leaves aisle gaps. */
const NAV_CHAIR_INSET = 0.18;
/** Mild inset for bulky desks / cabinets (walls & thin décor stay exact). */
const NAV_BULK_INSET = 0.05;

function isThinNavObstacle(o: Aabb2): boolean {
  return Math.min(o.maxX - o.minX, o.maxZ - o.minZ) < 0.12;
}

function isChairLikeObstacle(o: Aabb2): boolean {
  const w = o.maxX - o.minX;
  const d = o.maxZ - o.minZ;
  const area = w * d;
  return area < 1.2 && Math.min(w, d) < 0.95 && Math.max(w, d) < 1.5;
}

/**
 * Obstacles used for walkability + runtime slide. Mesh AABBs are slightly
 * inset so NAV_CLEARANCE (= AGENT_RADIUS) keeps a single connected aisle graph
 * without carving through walls.
 */
export const NAV_OBSTACLES: Aabb2[] = OFFICE_OBSTACLES.map((o) => {
  if (isThinNavObstacle(o)) return o;
  const inset = isChairLikeObstacle(o) ? NAV_CHAIR_INSET : NAV_BULK_INSET;
  return {
    minX: o.minX + inset,
    maxX: o.maxX - inset,
    minZ: o.minZ + inset,
    maxZ: o.maxZ - inset,
  };
}).filter((o) => o.maxX > o.minX + 0.05 && o.maxZ > o.minZ + 0.05);

/**
 * Aisle anchor points (all verified walkable with clearance).
 * Kept for patrol loop construction and debug tooling; pathfinding itself
 * runs on the occupancy grid.
 */
export const OFFICE_NAV_NODES: NavNode[] = [
  { id: "nw", x: -5.55, z: -5.2 },
  { id: "n_lounge", x: -3.46, z: -5.16 },
  { id: "n_mid", x: -0.5, z: -5.0 },
  { id: "n_sofa", x: 1.8, z: -5.2 },
  { id: "ne", x: 5.4, z: -5.2 },
  { id: "w_aisle", x: -5.85, z: -0.8 },
  { id: "mid_w", x: -3.4, z: -1.9 },
  { id: "mid_c", x: 0.4, z: -1.8 },
  { id: "mid_e", x: 3.3, z: -1.3 },
  { id: "e_door", x: 4.1, z: -1.3 },
  { id: "e_room", x: 5.6, z: -1.2 },
  { id: "sw", x: -5.4, z: 3.2 },
  { id: "s_mid", x: -1.45, z: 3.6 },
  { id: "s_coffee", x: 2.2, z: 3.4 },
  { id: "se", x: 3.5, z: 1.8 },
  { id: "foosball_s", x: 1.85, z: 3.55 },
  { id: "foosball_n", x: 1.91, z: 5.59 },
  { id: "sofa_appr", x: 1.79, z: -5.2 },
  { id: "coffee", x: -1.99, z: -5.2 },
];

export const OFFICE_POIS: OfficePoi[] = [
  {
    id: "foosball",
    kind: "foosball",
    capacity: 2,
    // soccer table.001 X[1.42,2.27] Z[4.13,5.21] — players on ±Z ends.
    approach: [{ x: 1.85, z: 3.55 }],
    queueSlots: [{ x: 2.6, z: 3.2 }],
    slots: [
      {
        id: "foosball_a",
        // South end — face +Z into the table.
        position: { x: 1.85, z: 3.82 },
        facing: 0,
        animation: "playing_foosball",
      },
      {
        id: "foosball_b",
        // North end — face −Z into the table.
        position: { x: 1.85, z: 5.5 },
        facing: Math.PI,
        animation: "playing_foosball",
      },
    ],
  },
  {
    id: "sofa_main",
    kind: "sofa",
    capacity: 3,
    // Cube.021 cushions; approach stays in the walkable aisle.
    approach: [{ x: 1.79, z: -5.2 }],
    slots: [
      {
        id: "sofa_a",
        // Slightly into the seat (not on the front lip) so thighs rest on cushions.
        position: { x: 1.27, z: -6.0 },
        facing: 0,
        animation: "sitting_sofa",
        // Cube.021 seat band ≈ 0.40–0.45; aim hips a bit above the surface.
        seatHeight: 0.48,
      },
      {
        id: "sofa_b",
        position: { x: 1.79, z: -6.0 },
        facing: 0,
        animation: "sitting_sofa",
        seatHeight: 0.48,
      },
      {
        id: "sofa_c",
        position: { x: 2.31, z: -6.0 },
        facing: 0,
        animation: "sitting_sofa",
        seatHeight: 0.48,
      },
    ],
  },
  {
    id: "coffee",
    kind: "coffee",
    capacity: 1,
    approach: [{ x: -1.99, z: -4.7 }],
    queueSlots: [
      { x: -1.2, z: -4.6 },
      { x: -0.7, z: -4.3 },
    ],
    slots: [
      {
        id: "coffee_active",
        position: { x: -1.99, z: -5.2 },
        facing: Math.PI,
        animation: "preparing_coffee",
      },
    ],
  },
];

export function dist2(a: NavPoint, b: NavPoint): number {
  const dx = a.x - b.x;
  const dz = a.z - b.z;
  return dx * dx + dz * dz;
}

export function pointInPolygon(p: NavPoint, poly: NavPoint[]): boolean {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    const yi = poly[i].z;
    const yj = poly[j].z;
    const xi = poly[i].x;
    const xj = poly[j].x;
    const intersect =
      yi > p.z !== yj > p.z && p.x < ((xj - xi) * (p.z - yi)) / (yj - yi + 1e-12) + xi;
    if (intersect) inside = !inside;
  }
  return inside;
}

/** Point inside a physical obstacle box (no clearance). */
export function pointHitsObstacle(p: NavPoint, obstacles: Aabb2[] = OFFICE_OBSTACLES): boolean {
  for (const o of obstacles) {
    if (p.x >= o.minX && p.x <= o.maxX && p.z >= o.minZ && p.z <= o.maxZ) return true;
  }
  return false;
}

function hitsInflated(x: number, z: number, pad: number, obstacles: Aabb2[] = NAV_OBSTACLES): boolean {
  for (const o of obstacles) {
    if (x >= o.minX - pad && x <= o.maxX + pad && z >= o.minZ - pad && z <= o.maxZ + pad) {
      return true;
    }
  }
  return false;
}

/** Walkable = inside footprint and clear of every obstacle + clearance. */
export function isWalkable(p: NavPoint): boolean {
  if (!pointInPolygon(p, OFFICE_WALKABLE_POLYGON)) return false;
  return !hitsInflated(p.x, p.z, NAV_CLEARANCE);
}

/** Sample along a segment; true if every sample is walkable. */
export function segmentIsWalkable(a: NavPoint, b: NavPoint, steps?: number): boolean {
  const n = steps ?? Math.max(4, Math.ceil(Math.sqrt(dist2(a, b)) / 0.1));
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    const p = { x: a.x + (b.x - a.x) * t, z: a.z + (b.z - a.z) * t };
    if (!isWalkable(p)) return false;
  }
  return true;
}

/**
 * Push a candidate point out of inflated nav obstacles, then ensure it is
 * never left inside a raw mesh AABB. Defaults match planning (NAV_OBSTACLES +
 * NAV_CLEARANCE) so runtime and pathfinding share the same envelope.
 * Falls back to the nearest walkable grid cell when axis slides land in a
 * pinch between two inflated boxes.
 */
export function resolveCollision(
  p: NavPoint,
  obstacles: Aabb2[] = NAV_OBSTACLES,
  pad: number = NAV_CLEARANCE,
): NavPoint {
  let { x, z } = p;
  const margin = 0.02;

  const slide = (obs: Aabb2[], usePad: number): boolean => {
    let moved = false;
    for (const o of obs) {
      const minX = o.minX - usePad;
      const maxX = o.maxX + usePad;
      const minZ = o.minZ - usePad;
      const maxZ = o.maxZ + usePad;
      if (x < minX || x > maxX || z < minZ || z > maxZ) continue;
      const left = x - minX;
      const right = maxX - x;
      const bottom = z - minZ;
      const top = maxZ - z;
      const min = Math.min(left, right, bottom, top);
      if (min === left) x = minX - margin;
      else if (min === right) x = maxX + margin;
      else if (min === bottom) z = minZ - margin;
      else z = maxZ + margin;
      moved = true;
    }
    return moved;
  };

  for (let pass = 0; pass < 8; pass++) {
    const rawMoved = slide(OFFICE_OBSTACLES, 0);
    const navMoved = slide(obstacles, pad);
    if (!rawMoved && !navMoved) break;
  }

  const candidate = { x, z };
  if (!pointHitsObstacle(candidate) && isWalkable(candidate)) {
    return candidate;
  }
  // Pinch between adjacent inflated AABBs, or slide outside the footprint —
  // snap to nearest free cell.
  const free = nearestFreeCell(candidate, 24);
  return free ? pointOf(free.i, free.j) : candidate;
}

/* ---------- occupancy grid A* ---------- */

const CELL = 0.15;
const GRID_MIN_X = -6.6;
const GRID_MIN_Z = -6.6;
const GRID_W = Math.round((7.0 - GRID_MIN_X) / CELL);
const GRID_H = Math.round((5.8 - GRID_MIN_Z) / CELL);

let occupancy: Uint8Array | null = null;

function grid(): Uint8Array {
  if (occupancy) return occupancy;
  const g = new Uint8Array(GRID_W * GRID_H);
  for (let j = 0; j < GRID_H; j++) {
    for (let i = 0; i < GRID_W; i++) {
      const x = GRID_MIN_X + i * CELL;
      const z = GRID_MIN_Z + j * CELL;
      g[j * GRID_W + i] = isWalkable({ x, z }) ? 0 : 1;
    }
  }
  occupancy = g;
  return g;
}

function cellOf(p: NavPoint): { i: number; j: number } {
  return {
    i: Math.min(GRID_W - 1, Math.max(0, Math.round((p.x - GRID_MIN_X) / CELL))),
    j: Math.min(GRID_H - 1, Math.max(0, Math.round((p.z - GRID_MIN_Z) / CELL))),
  };
}

function pointOf(i: number, j: number): NavPoint {
  return { x: GRID_MIN_X + i * CELL, z: GRID_MIN_Z + j * CELL };
}

/** Nearest free cell to p (spiral search). Null if none within maxR cells. */
function nearestFreeCell(p: NavPoint, maxR = 14): { i: number; j: number } | null {
  const g = grid();
  const { i: ci, j: cj } = cellOf(p);
  if (!g[cj * GRID_W + ci]) return { i: ci, j: cj };
  for (let r = 1; r <= maxR; r++) {
    let best: { i: number; j: number } | null = null;
    let bestD = Infinity;
    for (let dj = -r; dj <= r; dj++) {
      for (let di = -r; di <= r; di++) {
        if (Math.max(Math.abs(di), Math.abs(dj)) !== r) continue;
        const i = ci + di;
        const j = cj + dj;
        if (i < 0 || i >= GRID_W || j < 0 || j >= GRID_H) continue;
        if (g[j * GRID_W + i]) continue;
        const d = di * di + dj * dj;
        if (d < bestD) {
          bestD = d;
          best = { i, j };
        }
      }
    }
    if (best) return best;
  }
  return null;
}

const DIRS: Array<[number, number, number]> = [
  [1, 0, 1], [-1, 0, 1], [0, 1, 1], [0, -1, 1],
  [1, 1, Math.SQRT2], [1, -1, Math.SQRT2], [-1, 1, Math.SQRT2], [-1, -1, Math.SQRT2],
];

function gridAStar(start: { i: number; j: number }, goal: { i: number; j: number }): NavPoint[] | null {
  const g = grid();
  const idx = (i: number, j: number) => j * GRID_W + i;
  const startI = idx(start.i, start.j);
  const goalI = idx(goal.i, goal.j);
  if (startI === goalI) return [pointOf(start.i, start.j)];

  const gScore = new Float64Array(GRID_W * GRID_H).fill(Infinity);
  const came = new Int32Array(GRID_W * GRID_H).fill(-1);
  gScore[startI] = 0;
  // Binary-heap-free open list: small grid, Map suffices.
  const open = new Map<number, number>([[startI, 0]]);
  const h = (i: number, j: number) => Math.hypot(i - goal.i, j - goal.j);

  while (open.size) {
    let current = -1;
    let bestF = Infinity;
    for (const [k, f] of open) {
      if (f < bestF) {
        bestF = f;
        current = k;
      }
    }
    if (current === goalI) {
      const cells: number[] = [current];
      while (came[cells[0]] >= 0) cells.unshift(came[cells[0]]);
      return cells.map((c) => pointOf(c % GRID_W, Math.floor(c / GRID_W)));
    }
    open.delete(current);
    const ci = current % GRID_W;
    const cj = Math.floor(current / GRID_W);
    for (const [di, dj, cost] of DIRS) {
      const ni = ci + di;
      const nj = cj + dj;
      if (ni < 0 || ni >= GRID_W || nj < 0 || nj >= GRID_H) continue;
      if (g[idx(ni, nj)]) continue;
      // No diagonal corner cutting.
      if (di !== 0 && dj !== 0 && (g[idx(ci + di, cj)] || g[idx(ci, cj + dj)])) continue;
      const t = gScore[current] + cost;
      const nIdx = idx(ni, nj);
      if (t < gScore[nIdx]) {
        gScore[nIdx] = t;
        came[nIdx] = current;
        open.set(nIdx, t + h(ni, nj));
      }
    }
  }
  return null;
}

/** Greedy line-of-sight smoothing over the walkable field. */
function smooth(pts: NavPoint[]): NavPoint[] {
  if (pts.length <= 2) return pts;
  const out: NavPoint[] = [pts[0]];
  let anchor = 0;
  while (anchor < pts.length - 1) {
    let far = anchor + 1;
    for (let k = pts.length - 1; k > anchor + 1; k--) {
      if (segmentIsWalkable(pts[anchor], pts[k])) {
        far = k;
        break;
      }
    }
    out.push(pts[far]);
    anchor = far;
  }
  return out;
}

/**
 * Grid A* between two points. The returned polyline starts at `from`.
 * When `from`/`to` sit inside furniture (desk seat, sofa) the path enters /
 * exits via the nearest free cell; the final in-furniture snap is appended
 * only with allowGoalInObstacle or when the goal is walkable.
 */
export function findPath(from: NavPoint, to: NavPoint, opts: FindPathOptions = {}): NavPoint[] {
  const start = nearestFreeCell(from);
  const goal = nearestFreeCell(to);
  if (!start || !goal) return [{ x: from.x, z: from.z }];

  const cells = gridAStar(start, goal);
  if (!cells) return [{ x: from.x, z: from.z }];

  const pts: NavPoint[] = [{ x: from.x, z: from.z }];
  const smoothed = smooth(cells);
  for (const p of smoothed) pts.push(p);

  if (opts.allowGoalInObstacle || isWalkable(to)) {
    pts.push({ x: to.x, z: to.z });
  }
  // Drop duplicate consecutive points.
  return pts.filter(
    (p, i) => i === 0 || Math.hypot(p.x - pts[i - 1].x, p.z - pts[i - 1].z) > 0.03,
  );
}

export function floorYAt(_x: number, _z: number): number {
  return OFFICE_FLOOR_Y;
}

export function poiById(id: string): OfficePoi | undefined {
  return OFFICE_POIS.find((p) => p.id === id);
}

export function secondaryActivityLabel(activity: SecondaryActivity): string | null {
  switch (activity) {
    case "walking":
      return "Walking";
    case "preparing_coffee":
      return "Preparing coffee";
    case "playing_foosball":
      return "Playing foosball";
    case "sitting_sofa":
      return "Sitting on sofa";
    case "scrolling":
      return "On phone";
    case "stretching":
      return "Stretching";
    case "looking_around":
      return "Looking around";
    default:
      return null;
  }
}
