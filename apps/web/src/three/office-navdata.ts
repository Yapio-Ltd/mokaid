/**
 * Office navigation data — generated from office.blend, not hand-authored.
 *
 * AXIS CONVENTION (this is what the previous data got wrong):
 * the glTF export mirrors Blender's X axis, so the mapping from a Blender
 * coordinate to the coordinate this file uses is
 *     sceneX = -blenderX,  sceneY = blenderZ,  sceneZ = -blenderY
 * Feeding the un-mirrored X in put every obstacle, desk and POI on the wrong
 * side of the room: agents "played foosball" three metres from the table and
 * walked straight through desks the data claimed were elsewhere.
 *
 * Regenerate with:
 *   blender --background office.blend --python scripts/dump_office_nav.py
 *
 * Obstacle boxes cover only geometry that intersects an agent's body slab
 * (0.10 m .. 1.75 m); rugs underfoot and ceiling lamps are excluded so they
 * do not block aisles. Wall segments are rasterised from the room shell, which
 * keeps door openings walkable.
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
  /** Cushion top Y in scene space (before centering). */
  seatHeight?: number;
}

/** Anchor point for sitting / standing interactions. */
export type SeatSocketKind = "desk" | "sofa" | "foosball" | "coffee";

export interface SeatSocket {
  id: string;
  position: NavPoint;
  facing: number;
  seatHeight: number;
  kind: SeatSocketKind;
  /** True when the agent sits (sofa/desk); false for stand poses. */
  sits: boolean;
}

export interface OfficePoi {
  id: string;
  kind: OfficePoiKind;
  capacity: number;
  slots: OfficePoiSlot[];
  /** Walkable spot an agent heads for before taking a slot. */
  approach: NavPoint[];
  queueSlots?: NavPoint[];
}

export interface FindPathOptions {
  /** Allow the final point inside an obstacle (sofa / desk seat snap). */
  allowGoalInObstacle?: boolean;
}

/** Agent collision radius (agent-agent separation & visuals). */
export const AGENT_RADIUS = 0.35;

/** Clearance between an agent's centre and any obstacle while walking. */
export const NAV_CLEARANCE = AGENT_RADIUS;

/** Max agents that share the 3D office (one desk each). */
export const MAX_OFFICE_SEATS = 9;

/** soccer table.001 measured in office.blend. */
export const FOOSBALL_TABLE_AABB: Aabb2 = {
  minX: -2.27,
  maxX: -1.42,
  minZ: 4.13,
  maxZ: 5.21,
};

/**
 * Seat surfaces measured from the mesh (top of Cube.021 / Object_122), not
 * guessed: hips land on the cushion instead of sinking into the frame.
 */
export const SOFA_SEAT_HEIGHT = 0.66;
export const DESK_SEAT_HEIGHT = 0.51;

/** How far a foosball player stands off the table frame. */
export const FOOSBALL_STAND_GAP = 0.45;

export interface DeskSeat extends NavPoint {
  facing: number;
  seatHeight: number;
}

/**
 * One chair per agent, taken from the Object_122 instances and spread across
 * the floor. `facing` looks at the paired desk.
 */
export const OFFICE_DESK_SLOTS: DeskSeat[] = [
  { x: 1.682, z: -4.243, facing: -0.0013, seatHeight: DESK_SEAT_HEIGHT }, // Object_122.009
  { x: 5.157, z: -2.781, facing: 0.0151, seatHeight: DESK_SEAT_HEIGHT }, // Object_122.003
  { x: -2.008, z: -2.157, facing: -3.1053, seatHeight: DESK_SEAT_HEIGHT }, // Object_122.007
  { x: 3.252, z: -0.540, facing: -1.7097, seatHeight: DESK_SEAT_HEIGHT }, // Object_122.002
  { x: 1.750, z: -0.520, facing: 1.7620, seatHeight: DESK_SEAT_HEIGHT }, // Object_122.001
  { x: -6.019, z: 0.665, facing: 2.5970, seatHeight: DESK_SEAT_HEIGHT }, // Object_122.012
  { x: -0.854, z: 1.075, facing: -3.0795, seatHeight: DESK_SEAT_HEIGHT }, // Object_122.006
  { x: 5.163, z: 1.445, facing: 3.1329, seatHeight: DESK_SEAT_HEIGHT }, // Object_122
  { x: 2.158, z: 3.190, facing: -3.1079, seatHeight: DESK_SEAT_HEIGHT }, // Object_122.004
];

/** Flat floor height once the GLB is planted at y=0. */
export const OFFICE_FLOOR_Y = 0;

/** Exterior walkable polygon (room shell footprint). */
export const OFFICE_WALKABLE_POLYGON: NavPoint[] = [
  { x: -7.3, z: -6.35 },
  { x: 6.95, z: -6.35 },
  { x: 6.95, z: 6.35 },
  { x: -7.3, z: 6.35 },
];

/**
 * Furniture and wall boxes intersecting the agent body slab, generated from
 * office.blend. Not inflated — walkability adds NAV_CLEARANCE.
 */
export const OFFICE_OBSTACLES: Aabb2[] = [
  { minX: -7.43, maxX: -7.39, minZ: -1.53, maxZ: 1.81 }, // tv.001
  { minX: -7.38, maxX: -4.39, minZ: -1.82, maxZ: -1.76 }, // Plane.014
  { minX: -7.38, maxX: -6.39, minZ: 2.32, maxZ: 2.38 }, // Plane.023
  { minX: -7.34, maxX: -6.43, minZ: -5.92, maxZ: -4.92 }, // model_2.001
  { minX: -7.32, maxX: -6.39, minZ: 2.36, maxZ: 2.94 }, // Plane.026
  { minX: -7.17, maxX: -6.64, minZ: -5.68, maxZ: -5.14 }, // model_0.001
  { minX: -7.14, maxX: -5.12, minZ: -6.48, maxZ: -5.80 }, // Rack
  { minX: -6.98, maxX: -6.81, minZ: -6.21, maxZ: -6.04 }, // Circle.013
  { minX: -6.84, maxX: -6.71, minZ: 2.65, maxZ: 2.78 }, // Cylinder.020
  { minX: -6.75, maxX: -6.53, minZ: -6.23, maxZ: -6.01 }, // Circle.012
  { minX: -6.75, maxX: -6.53, minZ: -6.23, maxZ: -6.01 }, // Circle.014
  { minX: -6.36, maxX: -5.71, minZ: -0.54, maxZ: 0.15 }, // Object_122.013
  { minX: -6.35, maxX: -5.69, minZ: 0.32, maxZ: 1.01 }, // Object_122.012
  { minX: -6.18, maxX: -5.26, minZ: -0.80, maxZ: 1.14 }, // Cube.011
  { minX: -6.17, maxX: -5.24, minZ: 3.06, maxZ: 4.72 }, // table 2
  { minX: -6.11, maxX: -5.76, minZ: 0.68, maxZ: 0.94 }, // Cube.055
  { minX: -6.10, maxX: -5.26, minZ: 2.95, maxZ: 3.88 }, // model_2.011
  { minX: -6.10, maxX: -5.87, minZ: 0.35, maxZ: 0.66 }, // Cube.056
  { minX: -6.01, maxX: -5.32, minZ: 0.80, maxZ: 1.45 }, // Object_122.011
  { minX: -6.00, maxX: -5.87, minZ: -6.19, maxZ: -6.07 }, // Circle.011
  { minX: -5.95, maxX: -5.46, minZ: 3.18, maxZ: 3.67 }, // model_0.005
  { minX: -5.81, maxX: -5.53, minZ: -6.34, maxZ: -6.07 }, // Sphere
  { minX: -5.77, maxX: -5.63, minZ: 0.22, maxZ: 0.39 }, // Plane.039
  { minX: -5.71, maxX: -5.48, minZ: -6.25, maxZ: -6.01 }, // Circle.010
  { minX: -5.57, maxX: -5.38, minZ: 0.65, maxZ: 0.81 }, // Cube.058
  { minX: -5.56, maxX: -5.41, minZ: -0.08, maxZ: 0.35 }, // Cube.057
  { minX: -5.33, maxX: -4.68, minZ: -0.22, maxZ: 0.48 }, // Object_122.010
  { minX: -4.96, maxX: -4.26, minZ: 3.21, maxZ: 3.89 }, // photocopy machine.001
  { minX: -4.95, maxX: -4.04, minZ: -2.86, maxZ: -1.85 }, // model_2.002
  { minX: -4.89, maxX: -3.98, minZ: 2.41, maxZ: 3.42 }, // model_2.003
  { minX: -4.78, maxX: -4.28, minZ: -2.58, maxZ: -2.08 }, // Cube.074
  { minX: -4.78, maxX: -4.28, minZ: 2.65, maxZ: 3.14 }, // Cube.018
  { minX: -4.42, maxX: -3.61, minZ: -6.45, maxZ: -5.81 }, // Mirror
  { minX: -4.25, maxX: -4.07, minZ: -6.13, maxZ: -5.95 }, // Circle.009
  { minX: -3.83, maxX: -3.69, minZ: -6.11, maxZ: -5.97 }, // Circle.008
  { minX: -3.40, maxX: -2.93, minZ: -6.47, maxZ: -6.08 }, // Plane.046
  { minX: -3.00, maxX: -1.06, minZ: -3.28, maxZ: -2.36 }, // Cube.005
  { minX: -2.93, maxX: -1.13, minZ: -3.21, maxZ: -2.45 }, // Plane.035
  { minX: -2.79, maxX: -1.37, minZ: -6.42, maxZ: -5.61 }, // Cube.020
  { minX: -2.70, maxX: -2.58, minZ: -2.67, maxZ: -2.54 }, // Cylinder.014
  { minX: -2.66, maxX: -0.92, minZ: -6.35, maxZ: -5.64 }, // Cube.021
  { minX: -2.41, maxX: -2.25, minZ: -5.98, maxZ: -5.74 }, // Plane.045
  { minX: -2.38, maxX: -1.67, minZ: -2.76, maxZ: -2.56 }, // Plane.008
  { minX: -2.35, maxX: -1.66, minZ: -2.49, maxZ: -1.83 }, // Object_122.007
  { minX: -2.33, maxX: -1.64, minZ: -3.74, maxZ: -3.09 }, // Object_122.008
  { minX: -2.27, maxX: -1.42, minZ: 4.13, maxZ: 5.21 }, // soccer table.001
  { minX: -2.25, maxX: -1.82, minZ: -3.07, maxZ: -2.92 }, // Cube.052
  { minX: -2.14, maxX: -1.44, minZ: -6.29, maxZ: -5.74 }, // Cube.024
  { minX: -1.94, maxX: -1.55, minZ: -5.89, maxZ: -5.82 }, // Cube.026
  { minX: -1.87, maxX: 0.07, minZ: -0.12, maxZ: 0.80 }, // Cube.006
  { minX: -1.80, maxX: -0.00, minZ: -0.04, maxZ: 0.71 }, // Plane.034
  { minX: -1.71, maxX: -0.94, minZ: 1.80, maxZ: 2.65 }, // model_2.010
  { minX: -1.68, maxX: -1.50, minZ: -3.01, maxZ: -2.83 }, // Circle.002
  { minX: -1.66, maxX: -1.43, minZ: 0.37, maxZ: 0.72 }, // Cube.048
  { minX: -1.64, maxX: -1.45, minZ: 0.39, maxZ: 0.70 }, // Cube.049
  { minX: -1.62, maxX: -0.97, minZ: 2.00, maxZ: 2.66 }, // Cube.016
  { minX: -1.42, maxX: -1.29, minZ: -2.66, maxZ: -2.49 }, // Cube.033
  { minX: -1.39, maxX: -0.61, minZ: -6.35, maxZ: -5.98 }, // Cube.025
  { minX: -1.37, maxX: -1.11, minZ: -3.19, maxZ: -2.84 }, // Cube.050
  { minX: -1.35, maxX: -1.12, minZ: -3.17, maxZ: -2.86 }, // Cube.051
  { minX: -1.34, maxX: -0.33, minZ: 0.10, maxZ: 0.31 }, // Plane.009
  { minX: -1.28, maxX: -1.10, minZ: 0.35, maxZ: 0.53 }, // Circle.001
  { minX: -1.21, maxX: -1.04, minZ: -6.27, maxZ: -6.10 }, // Plane.044
  { minX: -1.21, maxX: -1.07, minZ: -6.22, maxZ: -6.08 }, // Cylinder.023
  { minX: -1.20, maxX: 0.96, minZ: 2.07, maxZ: 4.94 }, // wall 1
  { minX: -1.20, maxX: -0.51, minZ: 0.75, maxZ: 1.40 }, // Object_122.006
  { minX: -1.07, maxX: 0.59, minZ: 2.97, maxZ: 3.89 }, // Cube.007
  { minX: -1.06, maxX: -0.18, minZ: 5.59, maxZ: 6.24 }, // Cube.060
  { minX: -1.05, maxX: 0.56, minZ: 3.06, maxZ: 3.79 }, // Plane.022
  { minX: -0.97, maxX: -0.58, minZ: 0.44, maxZ: 0.72 }, // model_1.001
  { minX: -0.94, maxX: -0.24, minZ: -6.35, maxZ: -5.68 }, // Cube.022
  { minX: -0.91, maxX: -0.79, minZ: -6.21, maxZ: -5.91 }, // Cube.077
  { minX: -0.89, maxX: -0.74, minZ: -6.16, maxZ: -6.06 }, // Plane.043
  { minX: -0.84, maxX: -0.70, minZ: -6.22, maxZ: -6.08 }, // Cylinder.005
  { minX: -0.83, maxX: -0.67, minZ: 3.41, maxZ: 3.63 }, // Cube.080
  { minX: -0.78, maxX: -0.28, minZ: -0.97, maxZ: -0.47 }, // Cube.075
  { minX: -0.77, maxX: -0.23, minZ: -1.02, maxZ: -0.41 }, // model_2.009
  { minX: -0.77, maxX: -0.66, minZ: -6.21, maxZ: -5.91 }, // Cube.078
  { minX: -0.64, maxX: 0.08, minZ: 3.10, maxZ: 3.30 }, // Plane.010
  { minX: -0.63, maxX: 0.06, minZ: 3.83, maxZ: 4.48 }, // Object_122.005
  { minX: -0.56, maxX: -0.31, minZ: -6.21, maxZ: -5.91 }, // Cube.079
  { minX: -0.51, maxX: -0.08, minZ: 3.49, maxZ: 3.64 }, // Cube.045
  { minX: -0.44, maxX: -0.17, minZ: 3.31, maxZ: 3.45 }, // Plane.037
  { minX: -0.33, maxX: -0.22, minZ: 0.34, maxZ: 0.48 }, // Cylinder.013
  { minX: -0.29, maxX: -0.25, minZ: -6.35, maxZ: -5.68 }, // Cube.023
  { minX: -0.24, maxX: -0.09, minZ: 0.45, maxZ: 0.64 }, // Cube.047
  { minX: -0.07, maxX: -0.00, minZ: -6.47, maxZ: -4.45 }, // Plane.006
  { minX: -0.06, maxX: 0.85, minZ: -6.55, maxZ: -5.54 }, // model_2
  { minX: -0.04, maxX: 0.87, minZ: 5.40, maxZ: 6.41 }, // model_2.006
  { minX: 0.10, maxX: 0.64, minZ: -6.30, maxZ: -5.77 }, // model_0
  { minX: 0.13, maxX: 0.66, minZ: 5.65, maxZ: 6.18 }, // model_0.002
  { minX: 0.13, maxX: 0.25, minZ: 3.33, maxZ: 3.46 }, // Cylinder.011
  { minX: 0.22, maxX: 0.37, minZ: 3.53, maxZ: 3.72 }, // Cube.041
  { minX: 0.71, maxX: 2.65, minZ: -3.88, maxZ: -2.96 }, // Cube
  { minX: 0.73, maxX: 3.25, minZ: -6.44, maxZ: -5.65 }, // Cube.002
  { minX: 0.81, maxX: 2.57, minZ: -3.81, maxZ: -3.06 }, // Plane.032
  { minX: 1.00, maxX: 3.27, minZ: 2.08, maxZ: 3.00 }, // Cube.008
  { minX: 1.01, maxX: 2.93, minZ: 0.79, maxZ: 1.32 }, // Cube.037
  { minX: 1.05, maxX: 3.20, minZ: 2.13, maxZ: 2.89 }, // Plane.020
  { minX: 1.24, maxX: 1.51, minZ: 2.61, maxZ: 2.78 }, // Cube.038
  { minX: 1.26, maxX: 1.49, minZ: 2.62, maxZ: 2.77 }, // Cube.039
  { minX: 1.32, maxX: 2.04, minZ: -3.34, maxZ: -3.14 }, // Plane.001
  { minX: 1.34, maxX: 2.03, minZ: -4.57, maxZ: -3.91 }, // Object_122.009
  { minX: 1.42, maxX: 2.08, minZ: -0.87, maxZ: -0.17 }, // Object_122.001
  { minX: 1.45, maxX: 2.00, minZ: 0.76, maxZ: 1.37 }, // model_2.004
  { minX: 1.45, maxX: 1.88, minZ: -3.62, maxZ: -3.47 }, // Cube.010
  { minX: 1.47, maxX: 2.11, minZ: -6.48, maxZ: -6.29 }, // Plane.016
  { minX: 1.55, maxX: 1.87, minZ: 0.91, maxZ: 1.23 }, // model_0.004
  { minX: 1.77, maxX: 2.49, minZ: 2.18, maxZ: 2.38 }, // Plane.011
  { minX: 1.81, maxX: 2.50, minZ: 2.86, maxZ: 3.52 }, // Object_122.004
  { minX: 1.89, maxX: 2.32, minZ: 2.57, maxZ: 2.72 }, // Cube.044
  { minX: 1.98, maxX: 2.90, minZ: -1.51, maxZ: 0.20 }, // Cube.004
  { minX: 2.01, maxX: 2.17, minZ: -3.72, maxZ: -3.57 }, // Plane.042
  { minX: 2.04, maxX: 2.50, minZ: 0.81, maxZ: 1.32 }, // model_2.012
  { minX: 2.07, maxX: 2.82, minZ: -1.41, maxZ: 0.10 }, // Plane.033
  { minX: 2.13, maxX: 2.39, minZ: 0.93, maxZ: 1.20 }, // model_0.006
  { minX: 2.14, maxX: 2.29, minZ: -0.89, maxZ: -0.46 }, // Cube.046
  { minX: 2.20, maxX: 2.33, minZ: -3.80, maxZ: -3.67 }, // Plane.041
  { minX: 2.37, maxX: 2.53, minZ: -3.34, maxZ: -3.13 }, // Plane.018
  { minX: 2.39, maxX: 2.52, minZ: -3.78, maxZ: -3.61 }, // Cube.042
  { minX: 2.39, maxX: 2.66, minZ: -0.21, maxZ: -0.04 }, // Cube.034
  { minX: 2.41, maxX: 2.64, minZ: -0.20, maxZ: -0.05 }, // Cube.035
  { minX: 2.55, maxX: 2.70, minZ: 0.98, maxZ: 1.17 }, // Cube.019
  { minX: 2.55, maxX: 2.76, minZ: -1.02, maxZ: -0.30 }, // Plane.007
  { minX: 2.57, maxX: 2.69, minZ: 2.53, maxZ: 2.67 }, // Cylinder.001
  { minX: 2.67, maxX: 2.80, minZ: 2.76, maxZ: 2.88 }, // Cylinder.009
  { minX: 2.82, maxX: 2.99, minZ: 2.46, maxZ: 2.68 }, // Cube.040
  { minX: 2.92, maxX: 3.58, minZ: -0.89, maxZ: -0.19 }, // Object_122.002
  { minX: 3.17, maxX: 4.08, minZ: 1.79, maxZ: 2.79 }, // model_2.005
  { minX: 3.34, maxX: 4.32, minZ: 2.09, maxZ: 2.58 }, // Cube.017
  { minX: 3.55, maxX: 4.08, minZ: -6.46, maxZ: -5.89 }, // Plane.004
  { minX: 3.64, maxX: 4.89, minZ: -6.94, maxZ: -5.53 }, // model_4
  { minX: 3.76, maxX: 4.38, minZ: 1.97, maxZ: 2.66 }, // model_2.008
  { minX: 3.81, maxX: 4.02, minZ: -6.35, maxZ: -6.14 }, // Circle
  { minX: 3.94, maxX: 4.85, minZ: 2.78, maxZ: 3.79 }, // model_2.007
  { minX: 4.11, maxX: 4.64, minZ: 3.03, maxZ: 3.56 }, // model_0.003
  { minX: 4.11, maxX: 4.45, minZ: -6.36, maxZ: -6.02 }, // model_1.004
  { minX: 4.20, maxX: 6.14, minZ: -2.46, maxZ: -1.54 }, // Cube.001
  { minX: 4.29, maxX: 6.05, minZ: -2.37, maxZ: -1.62 }, // Plane.003
  { minX: 4.32, maxX: 6.02, minZ: 0.30, maxZ: 1.22 }, // Cube.003
  { minX: 4.40, maxX: 4.85, minZ: 0.38, maxZ: 1.13 }, // Plane.015
  { minX: 4.46, maxX: 6.49, minZ: -6.38, maxZ: -5.74 }, // Cube.012
  { minX: 4.49, maxX: 4.68, minZ: 0.88, maxZ: 1.12 }, // Cube.032
  { minX: 4.80, maxX: 6.36, minZ: -4.79, maxZ: -4.40 }, // Plane.036
  { minX: 4.81, maxX: 5.50, minZ: -3.11, maxZ: -2.45 }, // Object_122.003
  { minX: 4.81, maxX: 5.53, minZ: -1.98, maxZ: -1.78 }, // Plane.002
  { minX: 4.82, maxX: 5.51, minZ: 1.12, maxZ: 1.77 }, // Object_122
  { minX: 4.95, maxX: 5.38, minZ: -2.29, maxZ: -2.14 }, // Cube.043
  { minX: 5.04, maxX: 5.42, minZ: 0.64, maxZ: 0.91 }, // model_1
  { minX: 5.52, maxX: 5.64, minZ: -2.23, maxZ: -2.04 }, // Cube.028
  { minX: 5.53, maxX: 5.64, minZ: -2.22, maxZ: -2.05 }, // Cube.029
  { minX: 5.70, maxX: 5.83, minZ: -2.21, maxZ: -2.04 }, // Cube.027
  { minX: 5.72, maxX: 5.85, minZ: 0.64, maxZ: 0.76 }, // Cylinder.008
  { minX: 5.86, maxX: 6.02, minZ: -1.92, maxZ: -1.71 }, // Plane.012
  { minX: 5.88, maxX: 6.00, minZ: -1.88, maxZ: -1.74 }, // Cylinder.007
  { minX: -7.55, maxX: -7.45, minZ: -1.85, maxZ: 6.55 }, // wall
  { minX: -7.55, maxX: -7.35, minZ: -6.35, maxZ: -1.85 }, // wall
  { minX: -7.55, maxX: -7.15, minZ: -6.55, maxZ: -6.35 }, // wall
  { minX: -7.45, maxX: -7.35, minZ: 2.45, maxZ: 6.55 }, // wall
  { minX: -7.35, maxX: -6.15, minZ: 2.95, maxZ: 3.05 }, // wall
  { minX: -7.35, maxX: -4.95, minZ: -1.95, maxZ: -1.85 }, // wall
  { minX: -6.35, maxX: -6.25, minZ: 2.45, maxZ: 2.95 }, // wall
  { minX: -6.25, maxX: -6.15, minZ: 3.05, maxZ: 4.85 }, // wall
  { minX: -6.15, maxX: -5.15, minZ: 4.75, maxZ: 4.85 }, // wall
  { minX: -5.25, maxX: -5.15, minZ: 2.95, maxZ: 4.75 }, // wall
  { minX: -5.15, maxX: -5.05, minZ: -6.35, maxZ: -5.75 }, // wall
  { minX: -5.15, maxX: -4.45, minZ: -6.45, maxZ: -6.35 }, // wall
  { minX: -5.15, maxX: -0.05, minZ: -6.55, maxZ: -6.45 }, // wall
  { minX: -5.05, maxX: -4.95, minZ: 3.15, maxZ: 3.95 }, // wall
  { minX: -4.55, maxX: -4.45, minZ: -6.35, maxZ: -5.75 }, // wall
  { minX: -4.25, maxX: -4.15, minZ: 3.45, maxZ: 3.95 }, // wall
  { minX: -3.55, maxX: -3.45, minZ: -6.45, maxZ: -5.95 }, // wall
  { minX: -3.45, maxX: -2.85, minZ: -6.05, maxZ: -5.95 }, // wall
  { minX: -3.15, maxX: -3.05, minZ: -3.35, maxZ: -2.25 }, // wall
  { minX: -3.05, maxX: -2.35, minZ: -2.35, maxZ: -2.25 }, // wall
  { minX: -2.45, maxX: -2.35, minZ: -2.25, maxZ: -1.75 }, // wall
  { minX: -2.35, maxX: -2.25, minZ: 4.15, maxZ: 5.35 }, // wall
  { minX: -2.35, maxX: -1.65, minZ: -1.85, maxZ: -1.75 }, // wall
  { minX: -2.35, maxX: -1.25, minZ: 4.05, maxZ: 4.15 }, // wall
  { minX: -2.25, maxX: -1.35, minZ: 5.25, maxZ: 5.35 }, // wall
  { minX: -1.95, maxX: -1.85, minZ: -0.15, maxZ: 0.95 }, // wall
  { minX: -1.95, maxX: 0.15, minZ: -0.25, maxZ: -0.15 }, // wall
  { minX: -1.85, maxX: -1.25, minZ: 0.85, maxZ: 0.95 }, // wall
  { minX: -1.75, maxX: -1.25, minZ: 2.65, maxZ: 2.75 }, // wall
  { minX: -1.65, maxX: -1.55, minZ: -2.25, maxZ: -1.85 }, // wall
  { minX: -1.65, maxX: -0.95, minZ: -2.35, maxZ: -2.25 }, // wall
  { minX: -1.45, maxX: -1.25, minZ: 4.15, maxZ: 5.05 }, // wall
  { minX: -1.35, maxX: -1.25, minZ: 2.75, maxZ: 4.05 }, // wall
  { minX: -1.35, maxX: -0.05, minZ: -6.45, maxZ: -6.35 }, // wall
  { minX: -1.35, maxX: -0.05, minZ: -5.65, maxZ: -5.55 }, // wall
  { minX: -1.15, maxX: -1.05, minZ: 5.55, maxZ: 6.35 }, // wall
  { minX: -1.05, maxX: -0.95, minZ: -3.35, maxZ: -2.35 }, // wall
  { minX: -1.05, maxX: -0.05, minZ: 6.25, maxZ: 6.35 }, // wall
  { minX: -0.85, maxX: -0.75, minZ: -1.05, maxZ: -0.35 }, // wall
  { minX: -0.45, maxX: 0.15, minZ: 0.85, maxZ: 0.95 }, // wall
  { minX: -0.25, maxX: -0.15, minZ: -1.05, maxZ: -0.35 }, // wall
  { minX: -0.25, maxX: -0.05, minZ: -6.35, maxZ: -5.65 }, // wall
  { minX: -0.15, maxX: -0.05, minZ: -5.55, maxZ: -4.35 }, // wall
  { minX: -0.15, maxX: -0.05, minZ: 5.55, maxZ: 6.25 }, // wall
  { minX: 0.05, maxX: 0.15, minZ: -0.15, maxZ: 0.85 }, // wall
  { minX: 0.15, maxX: 0.65, minZ: -5.55, maxZ: -5.45 }, // wall
  { minX: 0.65, maxX: 2.75, minZ: -2.95, maxZ: -2.85 }, // wall
  { minX: 0.75, maxX: 3.15, minZ: 1.95, maxZ: 2.05 }, // wall
  { minX: 0.85, maxX: 3.35, minZ: -5.65, maxZ: -5.55 }, // wall
  { minX: 0.85, maxX: 3.65, minZ: -6.55, maxZ: -6.45 }, // wall
  { minX: 0.95, maxX: 1.05, minZ: 3.05, maxZ: 4.45 }, // wall
  { minX: 0.95, maxX: 3.05, minZ: 0.65, maxZ: 0.75 }, // wall
  { minX: 0.95, maxX: 3.05, minZ: 1.35, maxZ: 1.45 }, // wall
  { minX: 1.25, maxX: 1.35, minZ: -4.55, maxZ: -3.95 }, // wall
  { minX: 1.25, maxX: 2.05, minZ: -4.65, maxZ: -4.55 }, // wall
  { minX: 1.35, maxX: 1.45, minZ: -0.85, maxZ: -0.15 }, // wall
  { minX: 1.35, maxX: 1.95, minZ: -0.95, maxZ: -0.85 }, // wall
  { minX: 1.45, maxX: 1.95, minZ: -0.15, maxZ: -0.05 }, // wall
  { minX: 1.85, maxX: 1.95, minZ: -1.55, maxZ: -0.95 }, // wall
  { minX: 1.85, maxX: 3.05, minZ: -1.65, maxZ: -1.55 }, // wall
  { minX: 2.05, maxX: 2.15, minZ: -4.55, maxZ: -3.95 }, // wall
  { minX: 2.65, maxX: 2.75, minZ: -3.95, maxZ: -2.95 }, // wall
  { minX: 2.95, maxX: 3.05, minZ: -1.55, maxZ: -0.95 }, // wall
  { minX: 2.95, maxX: 3.05, minZ: 0.75, maxZ: 1.35 }, // wall
  { minX: 3.25, maxX: 3.35, minZ: -6.35, maxZ: -5.65 }, // wall
  { minX: 3.45, maxX: 3.55, minZ: -6.35, maxZ: -5.75 }, // wall
  { minX: 3.85, maxX: 3.95, minZ: 3.05, maxZ: 3.55 }, // wall
  { minX: 3.95, maxX: 4.45, minZ: -5.55, maxZ: -5.45 }, // wall
  { minX: 4.05, maxX: 4.15, minZ: -2.45, maxZ: -1.45 }, // wall
  { minX: 4.05, maxX: 4.75, minZ: -2.55, maxZ: -2.45 }, // wall
  { minX: 4.15, maxX: 6.25, minZ: -1.55, maxZ: -1.45 }, // wall
  { minX: 4.25, maxX: 4.75, minZ: 1.25, maxZ: 1.35 }, // wall
  { minX: 4.25, maxX: 6.15, minZ: 0.15, maxZ: 0.25 }, // wall
  { minX: 4.75, maxX: 5.55, minZ: 1.75, maxZ: 1.85 }, // wall
  { minX: 4.95, maxX: 6.55, minZ: -5.75, maxZ: -5.65 }, // wall
  { minX: 4.95, maxX: 7.15, minZ: -6.55, maxZ: -6.45 }, // wall
  { minX: 5.55, maxX: 6.15, minZ: 1.25, maxZ: 1.35 }, // wall
  { minX: 5.55, maxX: 6.25, minZ: -2.55, maxZ: -2.45 }, // wall
  { minX: 6.05, maxX: 6.15, minZ: 0.25, maxZ: 1.25 }, // wall
  { minX: 6.15, maxX: 6.25, minZ: -2.45, maxZ: -1.55 }, // wall
  { minX: 6.35, maxX: 6.45, minZ: -4.85, maxZ: -4.35 }, // wall
  { minX: 6.55, maxX: 7.15, minZ: -6.45, maxZ: -6.35 }, // wall
];

/**
 * Boxes used for walkability and runtime slide.
 *
 * Mesh AABBs are shrunk a touch so that adding NAV_CLEARANCE still leaves the
 * real aisles open: chair and table bounds include castors and overhangs an
 * agent's shoulders actually clear. Walls and thin dividers stay exact.
 */
/**
 * Mesh AABBs are axis-aligned around geometry that is not itself boxy — chair
 * castors, desk overhangs, plant leaves — so the raw box overstates what an
 * agent's body actually has to clear. Shrinking by this much keeps the office
 * a single connected walkable region at NAV_CLEARANCE; sweeping the value,
 * 0.06 severed the aisles into two islands and anything past 0.18 started
 * letting agents clip furniture corners.
 */
const NAV_BULK_INSET = 0.14;

function isThinNavObstacle(o: Aabb2): boolean {
  return Math.min(o.maxX - o.minX, o.maxZ - o.minZ) < 0.12;
}

export const NAV_OBSTACLES: Aabb2[] = OFFICE_OBSTACLES.map((o) => {
  if (isThinNavObstacle(o)) return o;
  return {
    minX: o.minX + NAV_BULK_INSET,
    maxX: o.maxX - NAV_BULK_INSET,
    minZ: o.minZ + NAV_BULK_INSET,
    maxZ: o.maxZ - NAV_BULK_INSET,
  };
}).filter((o) => o.maxX > o.minX + 0.04 && o.maxZ > o.minZ + 0.04);

/** Aisle anchors used for patrol loops and pinch escapes. */
export const OFFICE_NAV_NODES: NavNode[] = [
  { id: "n_sofa", x: -1.79, z: -5.05 },
  { id: "n_coffee", x: 1.99, z: -5.05 },
  { id: "n_east", x: 5.28, z: -4.16 },
  { id: "w_aisle", x: -4.3, z: -3.4 },
  { id: "mid_w", x: -3.4, z: -0.6 },
  { id: "mid_c", x: 0.35, z: -1.6 },
  { id: "mid_e", x: 4.0, z: -1.0 },
  { id: "s_mid", x: 0.31, z: 1.8 },
  { id: "foosball_s", x: -1.85, z: 3.6 },
  { id: "foosball_w", x: -2.85, z: 4.67 },
  { id: "sw", x: -3.7, z: 3.2 },
];

/**
 * Points of interest. Every slot and approach below was checked against the
 * rasterised office geometry: an agent body (0.35 m radius) fits, and the
 * approach is reachable from the aisles.
 */
export const OFFICE_POIS: OfficePoi[] = [
  {
    id: "foosball",
    kind: "foosball",
    capacity: 2,
    // The table's east flank is closed by desk 7, so the two players take the
    // west side and the south end — both verified free.
    approach: [{ x: -1.85, z: 3.6 }],
    queueSlots: [{ x: -2.9, z: 3.5 }],
    slots: [
      {
        id: "foosball_a",
        position: { x: -1.845, z: 3.68 },
        facing: 0,
        animation: "playing_foosball",
        seatHeight: 0,
      },
      {
        id: "foosball_b",
        position: { x: -2.72, z: 4.67 },
        facing: Math.PI / 2,
        animation: "playing_foosball",
        seatHeight: 0,
      },
    ],
  },
  {
    id: "sofa_main",
    kind: "sofa",
    capacity: 3,
    approach: [{ x: -1.79, z: -5.05 }],
    // Cushion top measured at 0.66; sitters sit clear of the Cube.024 backrest.
    slots: [
      {
        id: "sofa_a",
        position: { x: -2.31, z: -5.72 },
        facing: Math.PI,
        animation: "sitting_sofa",
        seatHeight: SOFA_SEAT_HEIGHT,
      },
      {
        id: "sofa_b",
        position: { x: -1.79, z: -5.72 },
        facing: Math.PI,
        animation: "sitting_sofa",
        seatHeight: SOFA_SEAT_HEIGHT,
      },
      {
        id: "sofa_c",
        position: { x: -1.27, z: -5.72 },
        facing: Math.PI,
        animation: "sitting_sofa",
        seatHeight: SOFA_SEAT_HEIGHT,
      },
    ],
  },
  {
    id: "coffee",
    kind: "coffee",
    capacity: 1,
    approach: [{ x: 1.99, z: -5.05 }],
    queueSlots: [
      { x: 1.2, z: -5.1 },
      { x: 2.7, z: -4.9 },
    ],
    slots: [
      {
        id: "coffee_active",
        // Standing clear of the counter (Cube.002 ends at z −5.65) with the
        // aisle in front measured free from z −5.15 outwards.
        position: { x: 1.99, z: -5.08 },
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
// Must span the whole walkable polygon. These were inherited from an older,
// smaller office box and cut off the north strip and the west wall, so any
// agent there had no grid cell to path from.
const GRID_MIN_X = -7.4;
const GRID_MIN_Z = -6.5;
const GRID_W = Math.round((7.1 - GRID_MIN_X) / CELL);
const GRID_H = Math.round((6.5 - GRID_MIN_Z) / CELL);

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

/**
 * Closest walkable aisle anchor to `from` (raw GLB space). Used to yank agents
 * out of dead-end pinches (e.g. meeting-room screen wall).
 */
export function nearestAislePoint(from: NavPoint): NavPoint {
  let best: NavPoint | null = null;
  let bestD = Infinity;
  for (const n of OFFICE_NAV_NODES) {
    if (!isWalkable(n)) continue;
    const d = dist2(from, n);
    if (d < bestD) {
      bestD = d;
      best = { x: n.x, z: n.z };
    }
  }
  if (best) return best;
  const cell = nearestFreeCell(from, 40);
  return cell ? pointOf(cell.i, cell.j) : { x: from.x, z: from.z };
}

export function poiById(id: string): OfficePoi | undefined {
  return OFFICE_POIS.find((p) => p.id === id);
}

/** Desk chair socket for seat_index. */
export function deskSocket(seatIndex: number): SeatSocket | null {
  const desk = OFFICE_DESK_SLOTS[seatIndex];
  if (!desk) return null;
  return {
    id: `desk_${seatIndex}`,
    position: { x: desk.x, z: desk.z },
    facing: desk.facing,
    seatHeight: desk.seatHeight,
    kind: "desk",
    sits: true,
  };
}

/** POI slot as a SeatSocket (sofa sits; foosball/coffee stand). */
export function poiSlotSocket(slotId: string): SeatSocket | null {
  for (const poi of OFFICE_POIS) {
    const slot = poi.slots.find((s) => s.id === slotId);
    if (!slot) continue;
    const sits = slot.animation === "sitting_sofa";
    return {
      id: slot.id,
      position: { x: slot.position.x, z: slot.position.z },
      facing: slot.facing,
      seatHeight: slot.seatHeight ?? 0,
      kind: poi.kind === "sofa" ? "sofa" : poi.kind === "foosball" ? "foosball" : "coffee",
      sits,
    };
  }
  return null;
}

/** Shortest distance from a point to an AABB edge (0 if inside). */
export function distToAabbEdge(p: NavPoint, box: Aabb2): number {
  const dx = Math.max(box.minX - p.x, 0, p.x - box.maxX);
  const dz = Math.max(box.minZ - p.z, 0, p.z - box.maxZ);
  if (dx === 0 && dz === 0) {
    // Inside — distance to nearest face (negative inward; report 0).
    return 0;
  }
  return Math.hypot(dx, dz);
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
