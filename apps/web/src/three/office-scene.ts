/**
 * OfficeScene: isolated Babylon.js layer.
 *
 * The 3D world is fully decoupled from React: it is created once, receives
 * agent updates through `updateAgents`, and reports interactions through
 * callbacks. Avatars load from the asset_3d catalog (male/female GLBs);
 * furniture remains procedural until environment assets ship.
 */

import {
  ArcRotateCamera,
  Color3,
  Color4,
  DirectionalLight,
  Engine,
  HemisphericLight,
  Matrix,
  Mesh,
  MeshBuilder,
  PointerEventTypes,
  Scene,
  ShadowGenerator,
  StandardMaterial,
  TransformNode,
  Vector3,
} from "@babylonjs/core";
import type { AbstractMesh, AnimationGroup } from "@babylonjs/core";
import { PBRMaterial } from "@babylonjs/core";
import { statusColors } from "@mokaid/design-tokens";
import {
  applyTint,
  DEFAULT_AVATAR_CDN_PATH,
  disposeAgentAnims,
  groundAgent,
  loadAgentModelTemplate,
  playAgentAnimation,
  resolveAgentGlbUrl,
  spawnAgentModel,
  type AgentAnimMap,
  type AgentAnimName,
  type AgentModelTemplate,
} from "./agent-model";
import {
  nearestWaypointIndex,
  pickPathNear,
  type IdleActivity,
  type OfficePath,
} from "./office-paths";
import type { SceneAgent, SceneCallbacks } from "./types";

/**
 * Desk pods: 3 rows of 3 desks. Two pods across the front, one across the
 * back-center, all axis-aligned and generously spaced so the aisles between
 * them stay wide and readable. Layout validated (no desk/zone/path overlap)
 * — see scratchpad/layout_v3.mjs.
 */
interface DeskPod {
  cx: number;
  cz: number;
}

const DESK_POD_SPACING = 3.4;
const DESK_PODS: DeskPod[] = [
  { cx: -6, cz: -5.5 }, // front-left
  { cx: 6, cz: -5.5 },  // front-right
  { cx: 0, cz: 2 },     // back-center
];

/** Desk x-offsets within a pod (3 desks side by side). */
const POD_DESK_OFFSETS = [-DESK_POD_SPACING, 0, DESK_POD_SPACING];

type IdleBehavior = "patrol" | IdleActivity;

interface AvatarNode {
  root: TransformNode;
  meshes: AbstractMesh[];
  ring: Mesh;
  agent: SceneAgent;
  phase: number;
  baseY: number;
  homePos: Vector3;
  labelHeight: number;
  anims: AgentAnimMap;
  idleAnim: AnimationGroup | null;
  walkAnim: AnimationGroup | null;
  currentAnim: AgentAnimName | null;
  activePath: OfficePath;
  pathIndex: number;
  idleBehavior: IdleBehavior;
  behaviorEnd: number;
  facing: number;
  avatarUrl: string;
  footOffset: number;
}

export class OfficeScene {
  private engine: Engine;
  private scene: Scene;
  private avatars = new Map<string, AvatarNode>();
  private deskSlots: Vector3[] = [];
  private materials = new Map<string, StandardMaterial>();
  private shadowGenerator: ShadowGenerator | null = null;
  private fpsTimer = 0;
  private disposed = false;
  private resizeObserver: ResizeObserver | null = null;
  /** Templates keyed by resolved GLB URL (supports male + female catalog). */
  private templates = new Map<string, AgentModelTemplate>();
  private templateLoads = new Map<string, Promise<AgentModelTemplate>>();
  private lastAgents: SceneAgent[] = [];

  constructor(
    private canvas: HTMLCanvasElement,
    private callbacks: SceneCallbacks,
  ) {
    this.engine = new Engine(canvas, true, {
      preserveDrawingBuffer: false,
      stencil: false,
      antialias: true,
      powerPreference: "high-performance",
    });

    this.scene = new Scene(this.engine);
    this.scene.clearColor = Color4.FromHexString("#0b0b10ff");

    this.setupCamera();
    this.setupLights();
    this.buildOffice();
    this.setupPicking();

    // Prefetch the default male avatar so the office populates quickly.
    void this.ensureTemplate(DEFAULT_AVATAR_CDN_PATH).then(() => {
      if (this.disposed) return;
      this.lastAgents.forEach((agent, index) => {
        if (!this.avatars.has(agent.id)) {
          void this.createAvatar(agent, agent.seatIndex >= 0 ? agent.seatIndex : index);
        }
      });
    });

    this.engine.runRenderLoop(() => {
      if (this.disposed) return;
      this.syncEngineSize();
      this.animate();
      this.scene.render();
      this.reportOverlay();
    });

    // Only resize the render buffer — never reframe the camera. The office
    // stays statically framed regardless of the side panel opening/closing.
    const resize = () => this.engine.resize();
    window.addEventListener("resize", resize);
    this.scene.onDisposeObservable.add(() => window.removeEventListener("resize", resize));

    // Layout changes (sidebar collapse, panels) resize the canvas without a
    // window resize event; observe the element itself so projected overlay
    // positions stay in sync with the render buffer.
    this.resizeObserver = new ResizeObserver(resize);
    this.resizeObserver.observe(canvas);
  }

  private agentAvatarUrl(agent: SceneAgent): string {
    return resolveAgentGlbUrl(agent.avatarCdnPath);
  }

  private ensureTemplate(cdnPathOrUrl: string | null | undefined): Promise<AgentModelTemplate> {
    const url = resolveAgentGlbUrl(cdnPathOrUrl);
    const cached = this.templates.get(url);
    if (cached) return Promise.resolve(cached);
    const pending = this.templateLoads.get(url);
    if (pending) return pending;
    const load = loadAgentModelTemplate(this.scene, url).then((template) => {
      this.templates.set(url, template);
      this.templateLoads.delete(url);
      return template;
    });
    this.templateLoads.set(url, load);
    return load;
  }

  /* ---------- setup ---------- */

  /**
   * Fixed camera framing. Radius is chosen large enough that the whole office
   * (23 × 19 footprint) stays visible even when the right side panel narrows
   * the canvas — the view is intentionally STATIC and never reframes on
   * resize, so opening/closing panels doesn't move the office.
   */
  // Radius 24 keeps the 23×19 footprint fully visible from the widest normal
  // canvas down to a narrow one (side panel open, aspect ~1.2) — verified in
  // scratchpad/framing3.mjs. It never reframes on resize.
  private static readonly CAMERA_RADIUS = 24;
  private static readonly CAMERA_FOV = 0.8; // vertical FOV, radians

  private setupCamera() {
    const camera = new ArcRotateCamera(
      "camera",
      -Math.PI / 3.2,
      Math.PI / 4.6,
      OfficeScene.CAMERA_RADIUS,
      new Vector3(0, 0, 0),
      this.scene,
    );
    camera.attachControl(this.canvas, true);
    camera.fov = OfficeScene.CAMERA_FOV;

    // Everything locked to the initial values — no orbit, pan, or zoom.
    camera.lowerRadiusLimit = OfficeScene.CAMERA_RADIUS;
    camera.upperRadiusLimit = OfficeScene.CAMERA_RADIUS;
    camera.lowerAlphaLimit = camera.alpha;
    camera.upperAlphaLimit = camera.alpha;
    camera.lowerBetaLimit = camera.beta;
    camera.upperBetaLimit = camera.beta;
    camera.panningSensibility = 0;

    // Remove wheel and drag/pinch input entirely so the view can't be
    // zoomed, orbited, or panned — angular sensibility 0 on drag also
    // causes division by zero and corrupts the camera (blank scene until
    // refresh), so dropping the input outright avoids that too.
    camera.inputs.removeByType("ArcRotateCameraMouseWheelInput");
    camera.inputs.removeByType("ArcRotateCameraPointersInput");
  }

  private setupLights() {
    const hemi = new HemisphericLight("hemi", new Vector3(0, 1, 0), this.scene);
    hemi.intensity = 0.65;
    hemi.groundColor = Color3.FromHexString("#1c1c26");

    const dir = new DirectionalLight("dir", new Vector3(-0.4, -1, -0.3), this.scene);
    dir.position = new Vector3(12, 18, 10);
    dir.intensity = 0.7;

    this.shadowGenerator = new ShadowGenerator(1024, dir);
    this.shadowGenerator.usePercentageCloserFiltering = true;
    this.shadowGenerator.setDarkness(0.55);
  }

  private material(key: string, hex: string, emissive = 0): StandardMaterial {
    const cacheKey = `${key}:${hex}:${emissive}`;
    let mat = this.materials.get(cacheKey);
    if (!mat) {
      mat = new StandardMaterial(cacheKey, this.scene);
      mat.diffuseColor = Color3.FromHexString(hex);
      mat.specularColor = new Color3(0.05, 0.05, 0.08);
      if (emissive > 0) {
        mat.emissiveColor = Color3.FromHexString(hex).scale(emissive);
      }
      this.materials.set(cacheKey, mat);
    }
    return mat;
  }

  /* ---------- procedural office (temporary assets) ---------- */

  private buildOffice() {
    // Floor
    const floor = MeshBuilder.CreateBox("floor", { width: 26, depth: 22, height: 0.4 }, this.scene);
    floor.position.y = -0.2;
    floor.material = this.material("floor", "#17171f");
    floor.receiveShadows = true;

    const rug = MeshBuilder.CreateBox("rug", { width: 21, depth: 17, height: 0.05 }, this.scene);
    rug.position.y = 0.03;
    rug.material = this.material("rug", "#1d1a2e");
    rug.receiveShadows = true;

    // Back walls (low, isometric style)
    const wallMat = this.material("wall", "#12121a");
    const wallA = MeshBuilder.CreateBox("wallA", { width: 26, depth: 0.3, height: 3.4 }, this.scene);
    wallA.position.set(0, 1.7, -11);
    wallA.material = wallMat;
    const wallB = MeshBuilder.CreateBox("wallB", { width: 0.3, depth: 22, height: 3.4 }, this.scene);
    wallB.position.set(-13, 1.7, 0);
    wallB.material = wallMat;

    // Window strip on back wall
    const windowStrip = MeshBuilder.CreateBox("window", { width: 18, depth: 0.1, height: 1.4 }, this.scene);
    windowStrip.position.set(0, 2, -10.8);
    const windowMat = this.material("window", "#2b2450", 0.35);
    windowMat.alpha = 0.9;
    windowStrip.material = windowMat;

    // Desk pods: 3 rows of 3, axis-aligned, wide aisles between them.
    let slot = 0;
    for (const pod of DESK_PODS) {
      for (const dx of POD_DESK_OFFSETS) {
        const x = pod.cx + dx;
        const z = pod.cz;
        this.buildDesk(x, z, slot);
        // Seat sits in front of the desk (chair is at +Z in desk-local space).
        this.deskSlots.push(new Vector3(x, 0, z + 1.15));
        slot += 1;
      }
    }

    // Plants: 4 corners + accents in the open aisles.
    for (const [x, z] of [
      [-11.5, -9.5],
      [11.5, -9.5],
      [-11.5, 9.5],
      [11.5, 9.5],
      [-11, 0],
      [11, 0],
    ] as const) {
      this.buildPlant(x, z);
    }

    this.buildMeetingRoom();
    this.buildLounge();
    this.buildFoosball();
  }

  /** Glass-walled meeting room in the back-right corner. */
  private buildMeetingRoom() {
    const cx = 9.5;
    const cz = 7.5;
    const glassMat = this.material("glass", "#5a4fb8", 0.15);
    glassMat.alpha = 0.25;

    // Two inner glass walls (the room's back/right sides are the room walls).
    const wallNorth = MeshBuilder.CreateBox("meeting-wall-north", { width: 7, depth: 0.12, height: 2.6 }, this.scene);
    wallNorth.position.set(cx, 1.3, cz - 3.3);
    wallNorth.material = glassMat;

    const wallWest = MeshBuilder.CreateBox("meeting-wall-west", { width: 0.12, depth: 6.6, height: 2.6 }, this.scene);
    wallWest.position.set(cx - 3.5, 1.3, cz);
    wallWest.material = glassMat;

    const table = MeshBuilder.CreateBox("meeting-table", { width: 3, depth: 1.4, height: 0.1 }, this.scene);
    table.position.set(cx, 0.85, cz);
    table.material = this.material("tabletop", "#2a2a38");
    const tableLeg = MeshBuilder.CreateBox("meeting-leg", { width: 0.12, depth: 1.2, height: 0.85 }, this.scene);
    tableLeg.position.set(cx, 0.42, cz);
    tableLeg.material = this.material("leg", "#3a3a4c");

    const screen = MeshBuilder.CreateBox("meeting-screen", { width: 2.2, depth: 0.08, height: 1.3 }, this.scene);
    screen.position.set(cx, 2, cz + 3.2);
    screen.material = this.material("screen", "#7c5cff", 0.4);
  }

  /** Lounge corner with a sofa, back-left. */
  private buildLounge() {
    const cx = -9.5;
    const cz = 7.5;

    const sofaBase = MeshBuilder.CreateBox("sofa-base", { width: 3.6, depth: 1.3, height: 0.55 }, this.scene);
    sofaBase.position.set(cx, 0.3, cz);
    sofaBase.material = this.material("sofa", "#2e2a44");
    this.shadowGenerator?.addShadowCaster(sofaBase);

    const sofaBack = MeshBuilder.CreateBox("sofa-back", { width: 3.6, depth: 0.3, height: 1 }, this.scene);
    sofaBack.position.set(cx, 0.75, cz + 0.5);
    sofaBack.material = this.material("sofa", "#2e2a44");

    const table = MeshBuilder.CreateCylinder("lounge-table", { diameter: 1.1, height: 0.1 }, this.scene);
    table.position.set(cx, 0.35, cz - 1.4);
    table.material = this.material("tabletop", "#2a2a38");
  }

  /** Foosball table in the open front-center area — a shared perk. */
  private buildFoosball() {
    const cx = 0;
    const cz = -8.7;

    const top = MeshBuilder.CreateBox("foosball-top", { width: 2.6, depth: 1.3, height: 0.12 }, this.scene);
    top.position.set(cx, 0.85, cz);
    top.material = this.material("foosball-top", "#1f6b45");
    this.shadowGenerator?.addShadowCaster(top);

    for (const [lx, lz] of [
      [-1.15, -0.5],
      [1.15, -0.5],
      [-1.15, 0.5],
      [1.15, 0.5],
    ] as const) {
      const leg = MeshBuilder.CreateBox("foosball-leg", { width: 0.1, depth: 0.1, height: 0.85 }, this.scene);
      leg.position.set(cx + lx, 0.42, cz + lz);
      leg.material = this.material("leg", "#3a3a4c");
    }

    const rail = MeshBuilder.CreateBox("foosball-rail", { width: 2.6, depth: 0.06, height: 0.06 }, this.scene);
    rail.position.set(cx, 0.94, cz);
    rail.material = this.material("leg", "#c9c9d4");
  }

  private buildDesk(x: number, z: number, index: number, rotationY = 0) {
    const group = new TransformNode(`desk-${index}`, this.scene);
    group.position.set(x, 0, z);
    group.rotation.y = rotationY;

    const top = MeshBuilder.CreateBox(`desk-top-${index}`, { width: 3, depth: 1.4, height: 0.12 }, this.scene);
    top.position.y = 1;
    top.parent = group;
    top.material = this.material("desktop", "#26263a");
    this.shadowGenerator?.addShadowCaster(top);

    for (const [lx, lz] of [
      [-1.35, -0.55],
      [1.35, -0.55],
      [-1.35, 0.55],
      [1.35, 0.55],
    ] as const) {
      const leg = MeshBuilder.CreateBox(`desk-leg-${index}-${lx}-${lz}`, { width: 0.1, depth: 0.1, height: 1 }, this.scene);
      leg.position.set(lx, 0.5, lz);
      leg.parent = group;
      leg.material = this.material("leg", "#3a3a4c");
    }

    // Monitor
    const screen = MeshBuilder.CreateBox(`monitor-${index}`, { width: 1.1, depth: 0.06, height: 0.65 }, this.scene);
    screen.position.set(0, 1.55, -0.35);
    screen.parent = group;
    screen.material = this.material("screen", "#7c5cff", 0.4);

    const stand = MeshBuilder.CreateBox(`monitor-stand-${index}`, { width: 0.12, depth: 0.12, height: 0.35 }, this.scene);
    stand.position.set(0, 1.2, -0.35);
    stand.parent = group;
    stand.material = this.material("leg", "#3a3a4c");

    // Chair
    const seat = MeshBuilder.CreateBox(`chair-seat-${index}`, { width: 0.9, depth: 0.9, height: 0.12 }, this.scene);
    seat.position.set(0, 0.55, 1.15);
    seat.parent = group;
    seat.material = this.material("chair", "#332f4a");

    const back = MeshBuilder.CreateBox(`chair-back-${index}`, { width: 0.9, depth: 0.1, height: 0.9 }, this.scene);
    back.position.set(0, 1.05, 1.58);
    back.parent = group;
    back.material = this.material("chair", "#332f4a");
  }

  private buildPlant(x: number, z: number) {
    const pot = MeshBuilder.CreateCylinder(`pot-${x}-${z}`, { diameterTop: 0.7, diameterBottom: 0.5, height: 0.6 }, this.scene);
    pot.position.set(x, 0.3, z);
    pot.material = this.material("pot", "#3f3358");

    const leaves = MeshBuilder.CreateSphere(`leaves-${x}-${z}`, { diameter: 1.3, segments: 8 }, this.scene);
    leaves.position.set(x, 1.2, z);
    leaves.scaling.y = 1.4;
    leaves.material = this.material("leaves", "#2f7d5a");
    this.shadowGenerator?.addShadowCaster(leaves);
  }

  /* ---------- avatars ---------- */

  updateAgents(agents: SceneAgent[]) {
    if (this.disposed) return;
    this.lastAgents = agents;

    const seen = new Set<string>();

    agents.forEach((agent, index) => {
      seen.add(agent.id);
      const existing = this.avatars.get(agent.id);
      const nextUrl = this.agentAvatarUrl(agent);

      if (existing) {
        // Swap mesh if the catalog asset changed.
        if (existing.avatarUrl !== nextUrl) {
          disposeAgentAnims(existing);
          existing.root.dispose();
          this.avatars.delete(agent.id);
          void this.createAvatar(agent, agent.seatIndex >= 0 ? agent.seatIndex : index);
          return;
        }

        const wasIdle = isIdleVisual(existing.agent.visualState);
        const nowIdle = isIdleVisual(agent.visualState);
        const colorChanged = existing.agent.color !== agent.color;
        existing.agent = agent;
        if (colorChanged) applyTint(existing.meshes, agent.color);
        if (wasIdle && !nowIdle) {
          existing.root.position.copyFrom(existing.homePos);
          groundAgent(existing.root, existing.footOffset);
          existing.idleBehavior = "patrol";
          playAgentAnimation(existing, "idle");
        } else if (!wasIdle && nowIdle) {
          existing.idleBehavior = "patrol";
          existing.behaviorEnd = 0;
          existing.activePath = pickPathNear(existing.root.position.x, existing.root.position.z);
          existing.pathIndex = nearestWaypointIndex(
            existing.activePath,
            existing.root.position.x,
            existing.root.position.z,
          );
        }
        this.applyStatusVisual(existing);
      } else {
        void this.createAvatar(agent, agent.seatIndex >= 0 ? agent.seatIndex : index);
      }
    });

    // Remove avatars for agents that no longer exist
    for (const [id, avatar] of this.avatars) {
      if (!seen.has(id)) {
        disposeAgentAnims(avatar);
        avatar.root.dispose();
        this.avatars.delete(id);
      }
    }
  }

  private async createAvatar(agent: SceneAgent, seatIndex: number) {
    if (this.disposed || this.avatars.has(agent.id)) return;

    let template: AgentModelTemplate;
    try {
      template = await this.ensureTemplate(agent.avatarCdnPath);
    } catch (err) {
      console.warn("[OfficeScene] failed to load avatar GLB for", agent.id, err);
      return;
    }
    if (this.disposed || this.avatars.has(agent.id)) return;

    const slot = this.deskSlots[seatIndex % this.deskSlots.length] ?? Vector3.Zero();
    const avatarUrl = this.agentAvatarUrl(agent);

    const spawned = spawnAgentModel(template, this.scene, agent.id, agent.color);
    const root = spawned.root;
    root.position.copyFrom(slot);
    groundAgent(root, template.footOffset);

    // Fallback: if the GLB produced no meshes (e.g. stale container after
    // a scene navigation), create a simple capsule so the agent is still
    // visible and the overlay/label still renders.
    if (spawned.meshes.length === 0) {
      console.warn("[OfficeScene] GLB spawn returned no meshes for agent", agent.id, "— using capsule fallback");
      const body = MeshBuilder.CreateCapsule(
        `fallback-body-${agent.id}`,
        { radius: 0.32, height: 1.5, subdivisions: 4 },
        this.scene,
      );
      body.position.y = 0.75;
      body.parent = root;
      body.material = this.material(`fallback-${agent.id}`, agent.color);
      body.isPickable = true;
      body.metadata = { agentId: agent.id };
      spawned.meshes.push(body);
    }

    const path = pickPathNear(slot.x, slot.z);
    const pathIndex = nearestWaypointIndex(path, slot.x, slot.z);

    const ring = MeshBuilder.CreateTorus(
      `avatar-ring-${agent.id}`,
      { diameter: 1.05, thickness: 0.06, tessellation: 24 },
      this.scene,
    );
    ring.position.y = 0.06;
    ring.parent = root;
    ring.isPickable = false;

    const avatar: AvatarNode = {
      root,
      meshes: spawned.meshes,
      ring,
      agent,
      phase: Math.random() * Math.PI * 2,
      baseY: root.position.y,
      homePos: slot.clone(),
      labelHeight: spawned.labelHeight,
      anims: spawned.anims,
      idleAnim: spawned.idleAnim,
      walkAnim: spawned.walkAnim,
      currentAnim: null,
      activePath: path,
      pathIndex,
      idleBehavior: "patrol",
      behaviorEnd: 0,
      facing: root.rotation.y,
      avatarUrl,
      footOffset: template.footOffset,
    };

    this.avatars.set(agent.id, avatar);
    for (const mesh of spawned.meshes) {
      this.shadowGenerator?.addShadowCaster(mesh);
    }
    playAgentAnimation(avatar, "idle");
    this.applyStatusVisual(avatar);
  }

  private applyStatusVisual(avatar: AvatarNode) {
    const statusColor =
      (statusColors as Record<string, string>)[avatar.agent.status] ?? statusColors.offline;

    avatar.ring.material = this.material(`ring-${avatar.agent.status}`, statusColor, 0.6);

    const isOffline = ["offline", "archived"].includes(avatar.agent.status);
    const alpha = isOffline ? 0.35 : 1;
    for (const mesh of avatar.meshes) {
      if (!mesh.material) continue;
      if (mesh.material instanceof StandardMaterial || mesh.material instanceof PBRMaterial) {
        mesh.material.alpha = alpha;
      }
    }
  }

  /* ---------- animation state machine ---------- */

  private animate() {
    const t = performance.now() / 1000;
    const dt = this.engine.getDeltaTime() / 1000;

    for (const avatar of this.avatars.values()) {
      const state = avatar.agent.visualState;

      if (isIdleVisual(state)) {
        this.animateIdle(avatar, t, dt);
        continue;
      }

      // Desk / status clips — prefer baked GLB animation over procedural bob.
      playAgentAnimation(avatar, state);
      const { root } = avatar;

      // Keep feet planted; celebrating bounce is in the clip (root.x translation).
      if (state === "away" || state === "offline") {
        root.position.y = avatar.baseY;
      }

      avatar.facing = root.rotation.y;
    }
  }

  /** Follow pre-traced paths; pause at waypoints for idle activities. */
  private animateIdle(avatar: AvatarNode, t: number, dt: number) {
    const { root, phase } = avatar;

    if (avatar.idleBehavior !== "patrol") {
      playAgentAnimation(avatar, "idle");
      if (t >= avatar.behaviorEnd) {
        avatar.idleBehavior = "patrol";
        return;
      }
      this.playIdleActivity(avatar, t, phase);
      return;
    }

    const wp = avatar.activePath.waypoints[avatar.pathIndex];
    if (!wp) {
      avatar.activePath = pickPathNear(root.position.x, root.position.z, avatar.activePath.id);
      avatar.pathIndex = 0;
      return;
    }

    const target = new Vector3(wp.x, root.position.y, wp.z);
    const arrived = this.walkToward(avatar, target, 1.4, dt);

    if (arrived) {
      playAgentAnimation(avatar, "idle");

      if (wp.activity) {
        avatar.idleBehavior = wp.activity;
        avatar.behaviorEnd = t + 4 + Math.random() * 5;
        return;
      }

      // Brief random pause (~25 %) at ordinary waypoints.
      if (Math.random() < 0.25) {
        const pauses: IdleActivity[] = ["look", "scrolling", "stretch"];
        avatar.idleBehavior = pauses[Math.floor(Math.random() * pauses.length)];
        avatar.behaviorEnd = t + 3 + Math.random() * 4;
        return;
      }

      avatar.pathIndex += 1;
      if (avatar.pathIndex >= avatar.activePath.waypoints.length) {
        if (avatar.activePath.loop) {
          avatar.pathIndex = 0;
        } else {
          avatar.activePath = pickPathNear(root.position.x, root.position.z, avatar.activePath.id);
          avatar.pathIndex = 0;
        }
      }
    }
  }

  private playIdleActivity(avatar: AvatarNode, t: number, phase: number) {
    const { root } = avatar;
    switch (avatar.idleBehavior) {
      case "coffee":
        root.rotation.y = Math.PI * 0.2;
        root.position.y = avatar.baseY + Math.sin((t + phase) * 2) * 0.01;
        break;
      case "scrolling":
        root.rotation.y = Math.sin((t + phase) * 0.25) * 0.2;
        break;
      case "stretch":
        root.rotation.y = Math.sin((t + phase) * 0.4) * 0.1;
        root.position.y = avatar.baseY + Math.sin((t + phase) * 1.5) * 0.02;
        break;
      case "look":
        root.rotation.y = Math.sin((t + phase) * 0.5) * 0.8;
        break;
      default:
        break;
    }

    avatar.facing = root.rotation.y;
  }

  /** Turn radians/sec while pivoting on the spot before stepping forward. */
  private static readonly TURN_SPEED = Math.PI * 2.2;
  /** Must be facing within this tolerance before advancing position. */
  private static readonly FACING_TOLERANCE = 0.08;

  private walkToward(avatar: AvatarNode, target: Vector3, speed: number, dt: number): boolean {
    const pos = avatar.root.position;
    const dx = target.x - pos.x;
    const dz = target.z - pos.z;
    const dist = Math.sqrt(dx * dx + dz * dz);

    if (dist < 0.25) {
      pos.x = target.x;
      pos.z = target.z;
      playAgentAnimation(avatar, "idle");
      return true;
    }

    const heading = Math.atan2(dx, dz);
    const turned = this.turnToward(avatar, heading, dt);

    if (!turned) {
      // Still pivoting on the spot — face the target before moving.
      playAgentAnimation(avatar, "idle");
      return false;
    }

    playAgentAnimation(avatar, "walking");
    const step = Math.min(speed * dt, dist);
    pos.x += (dx / dist) * step;
    pos.z += (dz / dist) * step;
    return false;
  }

  /** Smoothly rotate the avatar toward `heading`. Returns true once aligned. */
  private turnToward(avatar: AvatarNode, heading: number, dt: number): boolean {
    const twoPi = Math.PI * 2;
    let delta = (heading - avatar.facing) % twoPi;
    if (delta > Math.PI) delta -= twoPi;
    if (delta < -Math.PI) delta += twoPi;

    const maxStep = OfficeScene.TURN_SPEED * dt;
    if (Math.abs(delta) <= maxStep) {
      avatar.facing = heading;
    } else {
      avatar.facing += Math.sign(delta) * maxStep;
    }

    avatar.root.rotation.y = avatar.facing;
    return Math.abs(delta) <= OfficeScene.FACING_TOLERANCE;
  }

  /* ---------- picking ---------- */

  private setupPicking() {
    this.scene.onPointerObservable.add((info) => {
      if (info.type !== PointerEventTypes.POINTERTAP) return;

      const pick = this.scene.pick(this.scene.pointerX, this.scene.pointerY);
      const agentId = pick?.pickedMesh?.metadata?.agentId as string | undefined;
      this.callbacks.onSelectAgent(agentId ?? null);
    });
  }

  /* ---------- overlay + fps reporting ---------- */

  /** Keep the render buffer aligned with CSS size every frame (sidebar animation). */
  private syncEngineSize() {
    const cw = this.canvas.clientWidth;
    const ch = this.canvas.clientHeight;
    if (cw === 0 || ch === 0) return;

    const scale = this.engine.getHardwareScalingLevel();
    const expectedW = Math.floor(cw * scale);
    const expectedH = Math.floor(ch * scale);
    if (expectedW !== this.engine.getRenderWidth() || expectedH !== this.engine.getRenderHeight()) {
      this.engine.resize();
    }
  }

  private reportOverlay() {
    const now = performance.now();
    if (now - this.fpsTimer > 500) {
      this.fpsTimer = now;
      this.callbacks.onFps(Math.round(this.engine.getFps()));
    }

    const positions = new Map<string, { x: number; y: number; visible: boolean }>();
    const camera = this.scene.activeCamera;
    if (!camera) return;

    const cssW = this.canvas.clientWidth;
    const cssH = this.canvas.clientHeight;
    const renderW = this.engine.getRenderWidth();
    const renderH = this.engine.getRenderHeight();
    if (cssW === 0 || cssH === 0 || renderW === 0 || renderH === 0) return;

    for (const [id, avatar] of this.avatars) {
      const worldPos = avatar.root.getAbsolutePosition().add(new Vector3(0, avatar.labelHeight, 0));
      const projected = Vector3.Project(
        worldPos,
        Matrix.Identity(),
        this.scene.getTransformMatrix(),
        camera.viewport.toGlobal(renderW, renderH),
      );

      positions.set(id, {
        x: (projected.x / renderW) * cssW,
        y: (projected.y / renderH) * cssH,
        visible: projected.z > 0 && projected.z < 1,
      });
    }

    this.callbacks.onBubblePositions(positions);
  }

  getFps(): number {
    return Math.round(this.engine.getFps());
  }

  dispose() {
    this.disposed = true;
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
    this.engine.stopRenderLoop();
    this.scene.dispose();
    this.engine.dispose();
  }
}

// Only truly unoccupied agents roam the office. "waiting" (approval pending)
// stays at the desk: an agent with work in flight must look like it.
function isIdleVisual(state: string): boolean {
  return state === "idle" || state === "walking";
}
