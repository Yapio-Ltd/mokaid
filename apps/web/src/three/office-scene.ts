/**
 * OfficeScene: isolated Babylon.js layer.
 *
 * The 3D world is fully decoupled from React: it is created once, receives
 * agent updates through `updateAgents`, and reports interactions through
 * callbacks. The office environment loads from a hashed GLB; avatars load
 * from the asset_3d catalog (male/female GLBs).
 */

import {
  Color3,
  Color4,
  DefaultRenderingPipeline,
  Engine,
  FreeCamera,
  HemisphericLight,
  ImageProcessingConfiguration,
  Matrix,
  Mesh,
  MeshBuilder,
  PointLight,
  PointerEventTypes,
  Scene,
  SceneLoader,
  ShadowGenerator,
  SpotLight,
  StandardMaterial,
  TransformNode,
  Vector3,
} from "@babylonjs/core";
import type { AbstractMesh, AnimationGroup, Light } from "@babylonjs/core";
import { PBRMaterial } from "@babylonjs/core";
import "@babylonjs/loaders/glTF";
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
import { resolveOfficeGlbUrl } from "./office-asset";
import { fetchAssetCached } from "./asset-cache";
import {
  ENERGY_TO_INTENSITY_AREA,
  ENERGY_TO_INTENSITY_POINT,
  OFFICE_BLOOM,
  OFFICE_CAMERA,
  OFFICE_LIGHTS,
  type OfficeLightDef,
} from "./office-lighting";
import {
  OFFICE_DESK_SLOTS,
  OFFICE_PATHS,
  pathForSeat,
  routeToDesk,
  staggeredWaypointIndex,
  type IdleActivity,
  type OfficePath,
} from "./office-paths";
import type { CrowdAgent } from "recast-navigation";
import {
  createAgentCollider,
  createObstacleColliders,
  disposeObstacleColliders,
  setAgentCollisionsEnabled,
  syncColliderToRoot,
} from "./office-collisions";
import {
  addCrowdAgent,
  crowdAgentIsStuck,
  crowdClosestPoint,
  crowdGoto,
  crowdNavTarget,
  CROWD_MOVE_EPS,
  crowdPointInFurniture,
  crowdSpeed,
  crowdTeleport,
  createOfficeCrowd,
  type OfficeCrowd,
} from "./office-crowd";
import {
  AGENT_RADIUS,
  deskSocket,
  floorYAt,
  FOOSBALL_STAND_GAP,
  FOOSBALL_TABLE_AABB,
  isWalkable,
  MAX_OFFICE_SEATS,
  NAV_CLEARANCE,
  nearestAislePoint,
  OFFICE_OBSTACLES,
  poiById,
  poiSlotSocket,
  resolveCollision,
  type SeatSocket,
  type SecondaryActivity,
} from "./office-navdata";
import type { SceneAgent, SceneCallbacks } from "./types";

type IdleBehavior = "patrol" | IdleActivity | "poi" | "desk_sit";

interface SocketBlend {
  fromX: number;
  fromZ: number;
  fromY: number;
  fromYaw: number;
  toX: number;
  toZ: number;
  toY: number;
  toYaw: number;
  start: number;
  duration: number;
  anim: AgentAnimName | string;
  socketId: string;
  sits: boolean;
}

interface OfficeCamOverride {
  px: number;
  py: number;
  pz: number;
  tx: number;
  ty: number;
  tz: number;
  fov?: number;
  dist?: number;
}

/** Dev-only camera override: `?officeCam=px,py,pz,tx,ty,tz[,fov[,dist]]` (raw GLB coords). */
function readOfficeCamOverride(): OfficeCamOverride | null {
  if (typeof window === "undefined") return null;
  const raw = new URLSearchParams(window.location.search).get("officeCam");
  if (!raw) return null;
  const p = raw.split(",").map(Number);
  if (p.length < 6 || p.some((v) => Number.isNaN(v))) return null;
  return { px: p[0], py: p[1], pz: p[2], tx: p[3], ty: p[4], tz: p[5], fov: p[6], dist: p[7] };
}

type RenderQuality = "high" | "medium" | "low";

interface AvatarNode {
  root: TransformNode;
  /** Invisible Babylon collider with ellipsoid (world-space). */
  collider: Mesh;
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
  /**
   * Low-pass filtered walk heading. Detour's per-frame velocity wobbles under
   * obstacle avoidance; steering off the filtered value keeps turns readable.
   */
  headingFilter: number | null;
  /** POI slot exclusively held by this agent, if any. */
  claimedSlotId: string | null;
  avatarUrl: string;
  footOffset: number;
  /** Pelvis height above root while the sitting clip is active. */
  sitPelvisHeight: number;
  /** Desk chair facing (raw-authored) once centered home is set. */
  deskFacing: number;
  /** Desk chair cushion Y in raw GLB space. */
  deskSeatHeight: number;
  /** Last secondary activity reported to React. */
  reportedActivity: SecondaryActivity;
  routeBusy: boolean;
  /** Walking to desk chair after a task assignment. */
  deskRouteBusy: boolean;
  /** Visual state clip to play once seated at the desk. */
  pendingDeskState: AgentAnimName | string | null;
  /** True while locked onto a seat/stand socket (collisions off). */
  socketLocked: boolean;
  socketId: string | null;
  socketBlend: SocketBlend | null;
  /** Desk seat index used for exclusive patrol lane assignment. */
  seatIndex: number;
  /** Seconds spent making little progress toward the current waypoint. */
  stuckTimer: number;
  /** Last progress distance sample for stuck detection. */
  lastProgressDist: number;
  /** Anchor for immobility detection (ignores collision micro-jitter). */
  immobileAnchorX: number;
  immobileAnchorZ: number;
  /** Seconds spent near the immobility anchor while trying to walk. */
  noMoveTimer: number;
  /** Recast Crowd agent (null when crowd bake failed / fallback loco). */
  crowdAgent: CrowdAgent | null;
  /** Last crowd destination key to avoid re-issuing the same goto. */
  crowdTargetKey: string | null;
  /** Perf.now() until which recover is suppressed (stops thrash loops). */
  recoverUntil: number;
}

/**
 * Bump when collision / socket / locomotion logic changes so the singleton
 * scene is recreated instead of surviving with stale state. Re-exported by
 * office-scene-host and reported in the debug snapshot, so the number the
 * verification harness reads can never drift from the one the host compares.
 */
export const OFFICE_SCENE_BUILD = 16;

export class OfficeScene {
  private engine: Engine;
  private scene: Scene;
  private avatars = new Map<string, AvatarNode>();
  private deskSlots: Vector3[] = [];
  private materials = new Map<string, StandardMaterial>();
  private shadowGenerator: ShadowGenerator | null = null;
  private pipeline: DefaultRenderingPipeline | null = null;
  private sceneLights: Light[] = [];
  private fpsTimer = 0;
  private disposed = false;
  private resizeObserver: ResizeObserver | null = null;
  /** Templates keyed by resolved GLB URL (supports male + female catalog). */
  private templates = new Map<string, AgentModelTemplate>();
  private templateLoads = new Map<string, Promise<AgentModelTemplate>>();
  private lastAgents: SceneAgent[] = [];
  private officeReady = false;
  /** Patrol paths in the centered world frame (offset from raw GLB coords). */
  private paths: OfficePath[] = OFFICE_PATHS;
  private camera: FreeCamera | null = null;
  /** AABB centering offsets applied when the GLB loads. */
  private centerOffset = { x: 0, y: 0, z: 0 };
  private obstacleColliders: Mesh[] = [];
  /** Recast navmesh + Detour crowd (Babylon AI best practice). */
  private officeCrowd: OfficeCrowd | null = null;
  /** Runtime socket overrides calibrated from loaded GLB meshes (raw space). */
  private socketOverrides = new Map<string, SeatSocket>();
  /** slotId → agent id holding it. Keeps two agents out of the same socket. */
  private slotClaims = new Map<string, string>();
  private renderQuality: RenderQuality = "high";
  private lowFpsFrames = 0;
  /**
   * Native Retina scale set by Engine(adaptToDeviceRatio): typically 1/dpr
   * (e.g. 0.5 on a 2× display). Quality tiers are multiples of this base.
   */
  private readonly baseScale: number;
  private lastClientW = 0;
  private lastClientH = 0;
  private paused = false;

  constructor(
    private canvas: HTMLCanvasElement,
    private callbacks: SceneCallbacks,
  ) {
    this.engine = new Engine(
      canvas,
      true,
      {
        preserveDrawingBuffer: false,
        stencil: false,
        antialias: true,
        adaptToDeviceRatio: true,
        powerPreference: "high-performance",
        limitDeviceRatio: 2,
      },
      true,
    );
    this.baseScale = this.engine.getHardwareScalingLevel();

    this.scene = new Scene(this.engine);
    this.scene.clearColor = Color4.FromHexString("#050507ff");
    this.scene.ambientColor = new Color3(0.02, 0.02, 0.04);

    this.setupImageProcessing();
    this.setupCamera();
    this.setupAmbientLight();
    this.setupBloomPipeline();
    this.setupPicking();

    // Placeholder slots; replaced with centered coords after the GLB loads.
    this.deskSlots = OFFICE_DESK_SLOTS.map((s) => new Vector3(s.x, 0, s.z));

    void this.loadOfficeEnvironment();

    // Prefetch the default male avatar so the office populates quickly once
    // the environment finishes centering desk slots.
    void this.ensureTemplate(DEFAULT_AVATAR_CDN_PATH);

    this.startRenderLoop();

    // Only resize the render buffer — never reframe the camera. The office
    // stays statically framed regardless of the side panel opening/closing.
    const resize = () => {
      this.lastClientW = 0;
      this.lastClientH = 0;
      this.engine.resize();
    };
    window.addEventListener("resize", resize);
    this.scene.onDisposeObservable.add(() => window.removeEventListener("resize", resize));

    // Layout changes (sidebar collapse, panels) resize the canvas without a
    // window resize event; observe the element itself so projected overlay
    // positions stay in sync with the render buffer.
    this.resizeObserver = new ResizeObserver(resize);
    this.resizeObserver.observe(canvas);

    if (import.meta.env.DEV) {
      // Dev-only inspection handle (used by tooling/scripts to audit layout).
      (window as unknown as Record<string, unknown>).__mokaidOffice = this;
    }
  }

  /**
   * Dev tooling: teleport an avatar onto a sofa slot and apply the sitting pose.
   * Returns diagnostic pelvis / root heights for visual QA scripts.
   */
  debugSitOnSofa(slotId = "sofa_b"): {
    ok: boolean;
    rootY?: number;
    seatY?: number;
    sitPelvisHeight?: number;
    hipsY?: number;
    anim?: string | null;
    sittingPlaying?: boolean;
  } {
    const poi = poiById("sofa_main");
    const slot = poi?.slots.find((s) => s.id === slotId) ?? poi?.slots[0];
    const avatar = this.avatars.values().next().value as AvatarNode | undefined;
    if (!poi || !slot || !avatar) return { ok: false };

    const socket = poiSlotSocket(slot.id);
    if (!socket) return { ok: false };
    avatar.agent = {
      ...avatar.agent,
      officePoiId: poi.id,
      officeSlotId: slot.id,
      secondaryActivity: "sitting_sofa",
      officeActivityPhase: "active",
      visualState: "idle",
    };
    avatar.idleBehavior = "poi";
    avatar.routeBusy = false;
    avatar.activePath = { id: `debug-sit-${slot.id}`, loop: false, waypoints: [] };
    avatar.pathIndex = 0;
    this.lastPoiKey.set(avatar.agent.id, `${poi.id}:${slot.id}`);
    this.blendToSocket(avatar, socket, "sitting", 0.2);
    this.reportActivity(avatar, slot.animation);

    const seatY = (slot.seatHeight ?? 0.48) - this.centerOffset.y;
    let hipsY: number | undefined;
    const stack: TransformNode[] = [avatar.root];
    while (stack.length) {
      const n = stack.pop()!;
      const base = n.name.split("|").pop()?.split("/").pop() ?? n.name;
      if (base === "Hips" || base === "hips" || base === "root.x") {
        n.computeWorldMatrix(true);
        hipsY = n.getAbsolutePosition().y;
        break;
      }
      for (const c of n.getChildren()) {
        if (c instanceof TransformNode) stack.push(c);
      }
    }
    const sit = avatar.anims.sitting;
    return {
      ok: true,
      rootY: avatar.root.position.y,
      seatY,
      sitPelvisHeight: avatar.sitPelvisHeight,
      hipsY,
      anim: avatar.currentAnim,
      sittingPlaying: Boolean(sit?.isPlaying),
    };
  }

  /** Dev tooling: mesh world AABBs in raw GLB coords (navdata frame). */
  debugSceneFootprint(): { minX: number; maxX: number; minZ: number; maxZ: number } | null {
    let minX = Infinity;
    let maxX = -Infinity;
    let minZ = Infinity;
    let maxZ = -Infinity;
    let seen = false;
    for (const mesh of this.scene.meshes) {
      if (!mesh.isEnabled() || mesh.name.startsWith("agent-")) continue;
      const bb = mesh.getBoundingInfo().boundingBox;
      minX = Math.min(minX, bb.minimumWorld.x + this.centerOffset.x);
      maxX = Math.max(maxX, bb.maximumWorld.x + this.centerOffset.x);
      minZ = Math.min(minZ, bb.minimumWorld.z + this.centerOffset.z);
      maxZ = Math.max(maxZ, bb.maximumWorld.z + this.centerOffset.z);
      seen = true;
    }
    return seen
      ? {
          minX: +minX.toFixed(2),
          maxX: +maxX.toFixed(2),
          minZ: +minZ.toFixed(2),
          maxZ: +maxZ.toFixed(2),
        }
      : null;
  }

  /**
   * Drop a bright emissive pillar at a raw office-GLB coordinate.
   *
   * The one honest way to check nav data against the render: if the marker
   * does not stand on the furniture the data claims is there, the coordinate
   * is wrong — no projection maths or screenshot squinting involved.
   */
  debugMarker(rawX: number, rawZ: number, hex = "#ff0055", height = 3): void {
    const pillar = MeshBuilder.CreateCylinder(
      `debug-marker-${rawX}-${rawZ}`,
      { height, diameter: 0.12 },
      this.scene,
    );
    pillar.position.set(rawX - this.centerOffset.x, height / 2, rawZ - this.centerOffset.z);
    const mat = new StandardMaterial(`debug-marker-mat-${rawX}-${rawZ}`, this.scene);
    mat.emissiveColor = Color3.FromHexString(hex);
    mat.disableLighting = true;
    pillar.material = mat;
    pillar.isPickable = false;
  }

  /**
   * Project a raw office-GLB point to canvas pixels. Lets a verification
   * script confirm that where the data puts an agent is where the camera
   * actually draws it, instead of eyeballing a screenshot.
   */
  debugProject(rawX: number, rawZ: number, y = 0): { x: number; y: number } | null {
    const camera = this.scene.activeCamera;
    if (!camera) return null;
    const world = new Vector3(rawX - this.centerOffset.x, y, rawZ - this.centerOffset.z);
    const w = this.engine.getRenderWidth();
    const h = this.engine.getRenderHeight();
    const p = Vector3.Project(
      world,
      Matrix.Identity(),
      this.scene.getTransformMatrix(),
      camera.viewport.toGlobal(w, h),
    );
    const cssW = this.canvas.clientWidth;
    const cssH = this.canvas.clientHeight;
    return { x: +((p.x / w) * cssW).toFixed(1), y: +((p.y / h) * cssH).toFixed(1) };
  }

  debugMeshBounds(nameFilter: string): Array<{
    name: string;
    min: { x: number; y: number; z: number };
    max: { x: number; y: number; z: number };
  }> {
    const rx = new RegExp(nameFilter, "i");
    const out: Array<{
      name: string;
      min: { x: number; y: number; z: number };
      max: { x: number; y: number; z: number };
    }> = [];
    for (const mesh of this.scene.meshes) {
      if (!rx.test(mesh.name)) continue;
      mesh.computeWorldMatrix(true);
      const bb = mesh.getBoundingInfo().boundingBox;
      out.push({
        name: mesh.name,
        min: {
          x: bb.minimumWorld.x + this.centerOffset.x,
          y: bb.minimumWorld.y + this.centerOffset.y,
          z: bb.minimumWorld.z + this.centerOffset.z,
        },
        max: {
          x: bb.maximumWorld.x + this.centerOffset.x,
          y: bb.maximumWorld.y + this.centerOffset.y,
          z: bb.maximumWorld.z + this.centerOffset.z,
        },
      });
    }
    return out;
  }

  private startRenderLoop() {
    this.engine.stopRenderLoop();
    this.engine.runRenderLoop(() => {
      if (this.disposed || this.paused) return;
      this.syncEngineSize();
      this.animate();
      this.scene.render();
      this.reportOverlay();
      this.adaptQuality();
    });
  }

  /** Swap React callbacks without rebuilding the WebGL context. */
  setCallbacks(callbacks: SceneCallbacks) {
    this.callbacks = callbacks;
    if (this.officeReady) {
      this.callbacks.onLoadProgress?.(1);
      this.callbacks.onOfficeReady?.(true);
    }
  }

  pause() {
    this.paused = true;
    this.engine.stopRenderLoop();
  }

  resume() {
    if (this.disposed) return;
    this.paused = false;
    this.startRenderLoop();
    this.engine.resize();
  }

  isReady(): boolean {
    return this.officeReady;
  }

  /** Dev/E2E: snapshot of loco state for browser verification. */
  debugLocoSnapshot(): {
    officeReady: boolean;
    crowdReady: boolean;
    buildHint: number;
    centerOffset: { x: number; z: number };
    agents: Array<{
      name: string;
      x: number;
      z: number;
      /** Raw office-GLB coords, so checks can compare against furniture AABBs. */
      rawX: number;
      rawZ: number;
      y: number;
      absX: number;
      absZ: number;
      meshX?: number;
      meshZ?: number;
      speed: number;
      inFurniture: boolean;
      behavior: string;
      activity: SecondaryActivity;
      slot: string | null;
      crowd: boolean;
    }>;
  } {
    const agents = [...this.avatars.values()].map((a) => {
      const speed = a.crowdAgent ? crowdSpeed(a.crowdAgent) : 0;
      return {
        name: a.agent.name,
        x: +a.root.position.x.toFixed(3),
        z: +a.root.position.z.toFixed(3),
        rawX: +(a.root.position.x + this.centerOffset.x).toFixed(3),
        rawZ: +(a.root.position.z + this.centerOffset.z).toFixed(3),
        y: +a.root.position.y.toFixed(3),
        // World position the renderer actually draws — diverges from
        // root.position if a parent transform or stale world matrix creeps in.
        absX: +a.root.getAbsolutePosition().x.toFixed(3),
        absZ: +a.root.getAbsolutePosition().z.toFixed(3),
        // Centre of the drawn meshes, in world space. If this tracks absX/absZ
        // the avatar really is where the logic says; if it lags behind, the
        // visible body has detached from the node we move.
        ...(() => {
          const c = meshCentre(a);
          return c ? { meshX: +c.x.toFixed(3), meshZ: +c.z.toFixed(3) } : {};
        })(),
        speed: +speed.toFixed(3),
        inFurniture: crowdPointInFurniture(a.root.position.x, a.root.position.z, this.centerOffset),
        behavior: String(a.idleBehavior),
        activity: a.reportedActivity,
        slot: a.claimedSlotId,
        crowd: Boolean(a.crowdAgent),
      };
    });
    return {
      officeReady: this.officeReady,
      crowdReady: Boolean(this.officeCrowd),
      buildHint: OFFICE_SCENE_BUILD,
      centerOffset: {
        x: +this.centerOffset.x.toFixed(3),
        z: +this.centerOffset.z.toFixed(3),
      },
      agents,
    };
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

  /** Camera distance multiplier vs the calibrated OFFICE_CAMERA position. */
  private static readonly CAMERA_DISTANCE_SCALE = 1;

  /**
   * Per-material emissive intensities. Emission maps are baked in the GLB;
   * these values control how hard they drive the bloom threshold.
   */
  private static readonly EMISSIVE_BY_MATERIAL: Record<string, number> = {
    base: 5.0,
    "Solo items": 6.0,
    "dividing wall N": 5.0,
    additional: 5.5,
    Monitor: 2.2,
    "Monitor ": 2.2,
    "Lap Top": 2.4,
    Candles: 4.5,
    "Table Light": 4.5,
    Sofa: 3.5,
  };
  private static readonly EMISSIVE_DEFAULT = 3.0;

  private setupImageProcessing() {
    // Tone mapping / vignette are owned by DefaultRenderingPipeline once created;
    // configure the scene defaults here as a fallback before the pipeline attaches.
    const ip = this.scene.imageProcessingConfiguration;
    ip.toneMappingEnabled = true;
    ip.toneMappingType = ImageProcessingConfiguration.TONEMAPPING_ACES;
    ip.exposure = 1.05;
    ip.contrast = 1.12;
    ip.vignetteEnabled = true;
    ip.vignetteWeight = 1.4;
    ip.vignetteColor = new Color4(0, 0, 0, 1);
    ip.vignetteStretch = 0.2;
  }

  private setupCamera() {
    // Camera starts at raw GLB coords; reframed after environment centering.
    const cam = new FreeCamera("office-cam", Vector3.Zero(), this.scene);
    cam.fov = OFFICE_CAMERA.fovVertical;
    cam.minZ = OFFICE_CAMERA.near;
    cam.maxZ = OFFICE_CAMERA.far;
    cam.inertia = 0;
    cam.speed = 0;
    cam.inputs.clear();
    this.camera = cam;
    this.scene.activeCamera = cam;
    this.applyCameraPlacement(0, 0, 0);

    (window as unknown as { __officeCam?: typeof OFFICE_CAMERA }).__officeCam = OFFICE_CAMERA;
  }

  /**
   * Place the camera from the Blender viewport data, pulled toward the target
   * so the office fills the frame like the reference render. Supports a dev
   * override `?officeCam=px,py,pz,tx,ty,tz[,fov]` in raw GLB coords.
   */
  private applyCameraPlacement(centerX: number, minY: number, centerZ: number) {
    if (!this.camera) return;

    const override = readOfficeCamOverride();
    const raw = override ?? {
      px: OFFICE_CAMERA.position.x,
      py: OFFICE_CAMERA.position.y,
      pz: OFFICE_CAMERA.position.z,
      tx: OFFICE_CAMERA.target.x,
      ty: OFFICE_CAMERA.target.y,
      tz: OFFICE_CAMERA.target.z,
      fov: OFFICE_CAMERA.fovVertical,
      dist: OfficeScene.CAMERA_DISTANCE_SCALE,
    };

    const target = new Vector3(raw.tx - centerX, raw.ty - minY, raw.tz - centerZ);
    const pos = new Vector3(raw.px - centerX, raw.py - minY, raw.pz - centerZ);
    // Pull along the view axis (dist < 1 moves closer, keeps orientation).
    const scaled = target.add(pos.subtract(target).scale(raw.dist ?? 1));

    this.camera.position.copyFrom(scaled);
    this.camera.setTarget(target);
    if (raw.fov) this.camera.fov = raw.fov;
  }

  /** Very low ambient so PBR doesn't go pure black where lights don't reach. */
  private setupAmbientLight() {
    // Emulates the GI bounce the Cycles render gets from the neon strips.
    const hemi = new HemisphericLight("hemi-ambient", new Vector3(0, 1, 0), this.scene);
    hemi.intensity = 1.05;
    hemi.diffuse = Color3.FromHexString("#8f7fc4");
    hemi.groundColor = Color3.FromHexString("#453563");
    hemi.specular = Color3.Black();
    this.sceneLights.push(hemi);
  }

  private setupBloomPipeline() {
    if (!this.camera) return;
    const pipeline = new DefaultRenderingPipeline("office-pp", true, this.scene, [this.camera]);
    pipeline.bloomEnabled = true;
    pipeline.bloomThreshold = OFFICE_BLOOM.threshold;
    pipeline.bloomWeight = OFFICE_BLOOM.weight;
    pipeline.bloomKernel = OFFICE_BLOOM.kernel;
    pipeline.bloomScale = OFFICE_BLOOM.scale;
    // MSAA sharpens edges; FXAA is only used as a fallback on the low profile.
    pipeline.samples = 4;
    pipeline.fxaaEnabled = false;

    pipeline.imageProcessingEnabled = true;
    pipeline.imageProcessing.toneMappingEnabled = true;
    pipeline.imageProcessing.toneMappingType = ImageProcessingConfiguration.TONEMAPPING_ACES;
    pipeline.imageProcessing.exposure = 1.3;
    pipeline.imageProcessing.contrast = 1.08;
    pipeline.imageProcessing.vignetteEnabled = true;
    pipeline.imageProcessing.vignetteWeight = 1.4;
    pipeline.imageProcessing.vignetteColor = new Color4(0, 0, 0, 1);

    this.pipeline = pipeline;
  }

  /**
   * Recreate Blender point + area lights after the environment is centered.
   * AREA lights become overhead SpotLights (Babylon has no native area light).
   */
  private recreateBlenderLights(centerX: number, minY: number, centerZ: number) {
    // Dispose previous point/spot lights (keep ambient hemi).
    for (const light of this.sceneLights) {
      if (light.name !== "hemi-ambient") light.dispose();
    }
    this.sceneLights = this.sceneLights.filter((l) => l.name === "hemi-ambient");
    this.shadowGenerator?.dispose();
    this.shadowGenerator = null;

    let primaryShadow: ShadowGenerator | null = null;

    for (const def of OFFICE_LIGHTS) {
      const light = this.createLightFromDef(def, centerX, minY, centerZ);
      if (!light) continue;
      this.sceneLights.push(light);

      // Use the brightest point light for soft shadows (cheap single generator).
      if (!primaryShadow && light instanceof PointLight && def.energy >= 46) {
        primaryShadow = new ShadowGenerator(2048, light);
        primaryShadow.usePercentageCloserFiltering = true;
        primaryShadow.setDarkness(0.65);
      }
    }
    this.shadowGenerator = primaryShadow;
  }

  private createLightFromDef(
    def: OfficeLightDef,
    centerX: number,
    minY: number,
    centerZ: number,
  ): Light | null {
    const pos = new Vector3(
      def.position.x - centerX,
      def.position.y - minY,
      def.position.z - centerZ,
    );
    const color = new Color3(def.color.r, def.color.g, def.color.b);

    if (def.type === "POINT") {
      const light = new PointLight(`blend-${def.name}`, pos, this.scene);
      light.diffuse = color;
      light.specular = color.scale(0.4);
      light.intensity = def.energy * ENERGY_TO_INTENSITY_POINT;
      light.range = 7;
      light.falloffType = PointLight.FALLOFF_STANDARD;
      return light;
    }

    if (def.type === "AREA") {
      // Approximate downward area panels with a wide spot from above.
      const n = def.normal ?? { x: 0, y: -1, z: 0 };
      const direction = new Vector3(n.x, n.y, n.z);
      const light = new SpotLight(
        `blend-${def.name}`,
        pos,
        direction,
        Math.PI / 1.5,
        1.1,
        this.scene,
      );
      light.diffuse = color;
      light.specular = color.scale(0.25);
      light.intensity = def.energy * ENERGY_TO_INTENSITY_AREA;
      light.range = 12;
      return light;
    }

    return null;
  }

  /** Shift FreeCamera from raw GLB coords into the centered world frame. */
  private reframeCamera(centerX: number, minY: number, centerZ: number) {
    this.applyCameraPlacement(centerX, minY, centerZ);
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

  /* ---------- environment GLB ---------- */

  private async loadOfficeEnvironment() {
    const url = resolveOfficeGlbUrl();
    this.callbacks.onLoadProgress?.(0);

    try {
      // Prefer Cache Storage so a return visit or hard refresh does not re-download
      // the ~46 MB environment GLB.
      const buffer = await fetchAssetCached(url, (p) => this.callbacks.onLoadProgress?.(p * 0.95));
      if (this.disposed) return;

      const file = new File([buffer], "office.glb", { type: "model/gltf-binary" });
      const result = await SceneLoader.ImportMeshAsync("", "", file, this.scene);

      if (this.disposed) return;

      const root = new TransformNode("office-environment", this.scene);

      // glTF loader parents content under __root__; re-parent top-level nodes
      // so we can center/scale the whole office as one unit.
      const topLevel = [
        ...result.meshes.filter((m) => !m.parent),
        ...result.transformNodes.filter((t) => !t.parent),
      ];
      for (const node of topLevel) {
        node.parent = root;
      }

      for (const mesh of result.meshes) {
        mesh.isPickable = false;
        mesh.receiveShadows = true;
        this.toneDownEmissive(mesh);
        if (mesh instanceof Mesh) {
          this.shadowGenerator?.addShadowCaster(mesh);
        }
      }

      this.applyAnisotropicFiltering(16);

      // Center footprint on XZ and plant the floor at y=0.
      root.computeWorldMatrix(true);
      const bi = root.getHierarchyBoundingVectors(true);
      const centerX = (bi.min.x + bi.max.x) / 2;
      const centerZ = (bi.min.z + bi.max.z) / 2;
      const minY = bi.min.y;
      root.position.set(-centerX, -minY, -centerZ);
      root.computeWorldMatrix(true);
      this.centerOffset = { x: centerX, y: minY, z: centerZ };

      // Recast Crowd owns locomotion — Babylon furniture boxes fight the navmesh
      // (re-enable only if crowd bake fails; see bakeOfficeCrowd fallback).
      disposeObstacleColliders(this.obstacleColliders);
      this.scene.collisionsEnabled = false;
      this.checkFoosballTableDrift();

      this.recreateBlenderLights(centerX, minY, centerZ);
      this.reframeCamera(centerX, minY, centerZ);

      // Desk slots + patrol paths are authored in raw GLB space; apply centering.
      this.deskSlots = OFFICE_DESK_SLOTS.map(
        (s) => new Vector3(s.x - centerX, 0, s.z - centerZ),
      );
      this.paths = OFFICE_PATHS.map((path) => ({
        ...path,
        waypoints: path.waypoints.map((wp) => ({
          ...wp,
          x: wp.x - centerX,
          z: wp.z - centerZ,
        })),
      }));

      this.officeReady = true;
      this.callbacks.onLoadProgress?.(1);
      this.callbacks.onOfficeReady?.(true);

      // Bake Recast navmesh + crowd (async); agents fall back to A* until ready.
      void this.bakeOfficeCrowd();

      // Spawn any agents that arrived before the office finished loading.
      this.lastAgents.forEach((agent, index) => {
        if (!this.avatars.has(agent.id)) {
          void this.createAvatar(agent, agent.seatIndex >= 0 ? agent.seatIndex : index);
        }
      });
    } catch (err) {
      console.warn("[OfficeScene] failed to load office environment GLB", err);
      this.callbacks.onLoadProgress?.(1);
      this.callbacks.onOfficeReady?.(false);
    }
  }

  /** Keep textures crisp when viewed at grazing angles (desks, neon strips). */
  private applyAnisotropicFiltering(level: number) {
    for (const texture of this.scene.textures) {
      texture.anisotropicFilteringLevel = level;
    }
  }

  /** Apply per-material emissive caps so floor neon does not wash out bloom. */
  private toneDownEmissive(mesh: AbstractMesh) {
    const apply = (mat: unknown) => {
      if (!(mat instanceof PBRMaterial)) return;
      // Babylon defaults to 4 lights per material; the office has ~18.
      mat.maxSimultaneousLights = 24;
      const rawName = mat.name ?? "";
      const name = rawName.replace(/\s+$/, "").replace(/\.\d+$/, "");
      const target =
        OfficeScene.EMISSIVE_BY_MATERIAL[name] ??
        OfficeScene.EMISSIVE_BY_MATERIAL[rawName] ??
        OfficeScene.EMISSIVE_DEFAULT;
      mat.emissiveIntensity = target;
    };

    const mat = mesh.material;
    if (!mat) return;
    if ("subMaterials" in mat && Array.isArray((mat as { subMaterials: unknown[] }).subMaterials)) {
      for (const sub of (mat as { subMaterials: unknown[] }).subMaterials) apply(sub);
    } else {
      apply(mat);
    }
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
          existing.collider.dispose();
          existing.root.dispose();
          this.avatars.delete(agent.id);
          void this.createAvatar(agent, agent.seatIndex >= 0 ? agent.seatIndex : index);
          return;
        }

        const wasIdle = isIdleVisual(existing.agent.visualState);
        const nowIdle = isIdleVisual(agent.visualState);
        const colorChanged = existing.agent.color !== agent.color;
        existing.agent = agent;
        if (agent.seatIndex >= 0) existing.seatIndex = agent.seatIndex;
        if (colorChanged) applyTint(existing.meshes, agent.color);
        if (wasIdle && !nowIdle) {
          existing.idleBehavior = "desk_sit";
          existing.routeBusy = false;
          this.standFromSocket(existing);
          this.beginDeskSitRoute(existing, agent.visualState);
        } else if (!wasIdle && nowIdle) {
          existing.idleBehavior = "patrol";
          existing.behaviorEnd = 0;
          existing.stuckTimer = 0;
          existing.deskRouteBusy = false;
          existing.pendingDeskState = null;
          this.standFromSocket(existing);
          this.assignPatrolLane(existing);
        }
        this.syncServerActivity(existing);
        this.applyStatusVisual(existing);
      } else if (this.officeReady) {
        void this.createAvatar(agent, agent.seatIndex >= 0 ? agent.seatIndex : index);
      }
    });

    // Remove avatars for agents that no longer exist
    for (const [id, avatar] of this.avatars) {
      if (!seen.has(id)) {
        disposeAgentAnims(avatar);
        this.detachCrowdAgent(avatar);
        this.releaseSlot(avatar);
        avatar.collider.dispose();
        avatar.root.dispose();
        this.avatars.delete(id);
      }
    }
  }

  private async createAvatar(agent: SceneAgent, seatIndex: number) {
    if (this.disposed || this.avatars.has(agent.id)) return;
    if (seatIndex < 0 || seatIndex >= MAX_OFFICE_SEATS || seatIndex >= this.deskSlots.length) {
      console.warn("[OfficeScene] invalid seat_index", agent.id, seatIndex);
      return;
    }

    let template: AgentModelTemplate;
    try {
      template = await this.ensureTemplate(agent.avatarCdnPath);
    } catch (err) {
      console.warn("[OfficeScene] failed to load avatar GLB for", agent.id, err);
      return;
    }
    if (this.disposed || this.avatars.has(agent.id)) return;

    const desk = OFFICE_DESK_SLOTS[seatIndex];
    const slot = this.deskSlots[seatIndex] ?? Vector3.Zero();
    const avatarUrl = this.agentAvatarUrl(agent);

    const spawned = spawnAgentModel(template, this.scene, agent.id, agent.color);
    const root = spawned.root;
    root.position.copyFrom(slot);
    root.rotation.y = desk?.facing ?? 0;
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

    const path = pathForSeat(seatIndex, this.paths);
    const pathIndex = staggeredWaypointIndex(path, slot.x, slot.z, seatIndex);

    const ring = MeshBuilder.CreateTorus(
      `avatar-ring-${agent.id}`,
      { diameter: 1.05, thickness: 0.06, tessellation: 24 },
      this.scene,
    );
    ring.position.y = 0.06;
    ring.parent = root;
    ring.isPickable = false;

    const collider = createAgentCollider(this.scene, agent.id);
    syncColliderToRoot(collider, root);

    const avatar: AvatarNode = {
      root,
      collider,
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
      headingFilter: null,
      claimedSlotId: null,
      avatarUrl,
      footOffset: template.footOffset,
      sitPelvisHeight: template.sitPelvisHeight,
      deskFacing: desk?.facing ?? 0,
      deskSeatHeight: desk?.seatHeight ?? 0.5,
      reportedActivity: null,
      routeBusy: false,
      deskRouteBusy: false,
      pendingDeskState: null,
      socketLocked: false,
      socketId: null,
      socketBlend: null,
      seatIndex,
      stuckTimer: 0,
      lastProgressDist: Infinity,
      immobileAnchorX: root.position.x,
      immobileAnchorZ: root.position.z,
      noMoveTimer: 0,
      crowdAgent: null,
      crowdTargetKey: null,
      recoverUntil: 0,
    };
    this.attachCrowdAgent(avatar);

    this.avatars.set(agent.id, avatar);
    if (isIdleVisual(agent.visualState)) {
      this.plantFeet(avatar);
      playAgentAnimation(avatar, "idle");
    } else {
      // Spawn already at the desk — sit immediately without walking.
      this.snapToDeskSocket(avatar, agent.visualState);
    }
    for (const mesh of spawned.meshes) {
      this.shadowGenerator?.addShadowCaster(mesh);
    }
    this.syncServerActivity(avatar);
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
    const dt = Math.min(0.05, this.engine.getDeltaTime() / 1000);

    // Detour Crowd advances all agents first (navmesh-constrained loco).
    this.officeCrowd?.crowd.update(dt);

    for (const avatar of this.avatars.values()) {
      if (avatar.socketBlend) {
        this.tickSocketBlend(avatar, t);
        continue;
      }

      const state = avatar.agent.visualState;

      if (avatar.deskRouteBusy || avatar.idleBehavior === "desk_sit") {
        this.animateDeskSit(avatar, t, dt);
        continue;
      }

      if (isIdleVisual(state)) {
        this.animateIdle(avatar, t, dt);
        continue;
      }

      // Working / busy — leave crowd and sit at desk.
      this.pauseCrowdAgent(avatar);
      if (!avatar.socketLocked || avatar.socketId !== `desk_${avatar.seatIndex}`) {
        this.snapToDeskSocket(avatar, state);
      } else {
        playAgentAnimation(avatar, state as AgentAnimName);
      }
      if (state === "away" || state === "offline") {
        avatar.root.position.y = avatar.baseY;
      }

      avatar.facing = avatar.root.rotation.y;
      this.reportActivity(avatar, null);
    }
  }

  private async bakeOfficeCrowd() {
    try {
      const crowd = await createOfficeCrowd({
        x: this.centerOffset.x,
        z: this.centerOffset.z,
      });
      if (this.disposed) {
        crowd?.destroy();
        return;
      }
      this.officeCrowd?.destroy();
      this.officeCrowd = crowd;
      if (crowd) {
        // Crowd mode: no Babylon mesh collisions.
        disposeObstacleColliders(this.obstacleColliders);
        this.scene.collisionsEnabled = false;
        if (import.meta.env.DEV) {
          console.info("[OfficeScene] Recast crowd ready (navmesh loco, no mesh colliders)");
        }
      } else {
        // Fallback A*: software resolveCollision + optional Babylon boxes.
        this.scene.collisionsEnabled = true;
        disposeObstacleColliders(this.obstacleColliders);
        this.obstacleColliders = createObstacleColliders(this.scene, this.centerOffset);
        if (import.meta.env.DEV) {
          console.info("[OfficeScene] fallback loco + obstacle colliders:", this.obstacleColliders.length);
        }
      }
      for (const avatar of this.avatars.values()) {
        this.attachCrowdAgent(avatar);
      }
    } catch (err) {
      console.warn("[OfficeScene] Recast crowd bake failed — using fallback loco", err);
      this.officeCrowd = null;
      this.scene.collisionsEnabled = true;
      disposeObstacleColliders(this.obstacleColliders);
      this.obstacleColliders = createObstacleColliders(this.scene, this.centerOffset);
    }
  }

  private attachCrowdAgent(avatar: AvatarNode) {
    if (!this.officeCrowd || avatar.crowdAgent) return;
    let x = avatar.root.position.x;
    let z = avatar.root.position.z;
    // Spawn seats sit inside desks — snap onto the navmesh before adding.
    if (crowdPointInFurniture(x, z, this.centerOffset)) {
      const raw = nearestAislePoint({
        x: x + this.centerOffset.x,
        z: z + this.centerOffset.z,
      });
      x = raw.x - this.centerOffset.x;
      z = raw.z - this.centerOffset.z;
    }
    const snapped = crowdClosestPoint(this.officeCrowd.query, x, z);
    const agent = addCrowdAgent(
      this.officeCrowd.crowd,
      this.officeCrowd.query,
      snapped.x,
      snapped.z,
    );
    avatar.crowdAgent = agent;
    avatar.crowdTargetKey = null;
    if (agent) {
      setAgentCollisionsEnabled(avatar.collider, false);
      crowdTeleport(agent, this.officeCrowd.query, snapped.x, snapped.z);
      avatar.root.position.x = snapped.x;
      avatar.root.position.z = snapped.z;
      this.plantFeet(avatar);
      avatar.immobileAnchorX = snapped.x;
      avatar.immobileAnchorZ = snapped.z;
      avatar.noMoveTimer = 0;
    }
  }

  private detachCrowdAgent(avatar: AvatarNode) {
    if (!avatar.crowdAgent || !this.officeCrowd) return;
    try {
      this.officeCrowd.crowd.removeAgent(avatar.crowdAgent.agentIndex);
    } catch {
      /* already removed */
    }
    avatar.crowdAgent = null;
    avatar.crowdTargetKey = null;
  }

  /**
   * Push an idle agent off any neighbour standing too close.
   *
   * Only used while Detour is not steering (idle activities, held sockets):
   * during normal walking the crowd's own separation handles it, and fighting
   * it here would make agents jitter. The push is clamped to walkable space so
   * nudging someone out of a huddle never shoves them into furniture.
   */
  private separateFromNeighbours(avatar: AvatarNode) {
    const minGap = OfficeScene.SEPARATION;
    let pushX = 0;
    let pushZ = 0;
    for (const other of this.avatars.values()) {
      if (other === avatar) continue;
      const dx = avatar.root.position.x - other.root.position.x;
      const dz = avatar.root.position.z - other.root.position.z;
      const d2 = dx * dx + dz * dz;
      if (d2 >= minGap * minGap) continue;
      const d = Math.sqrt(d2);
      if (d < 1e-4) {
        // Exactly co-located: break the tie deterministically by seat index.
        pushX += Math.cos(avatar.seatIndex) * minGap * 0.5;
        pushZ += Math.sin(avatar.seatIndex) * minGap * 0.5;
        continue;
      }
      const overlap = (minGap - d) * 0.5;
      pushX += (dx / d) * overlap;
      pushZ += (dz / d) * overlap;
    }
    if (pushX === 0 && pushZ === 0) return;

    const raw = {
      x: avatar.root.position.x + pushX + this.centerOffset.x,
      z: avatar.root.position.z + pushZ + this.centerOffset.z,
    };
    if (!isWalkable(raw)) return;
    avatar.root.position.x += pushX;
    avatar.root.position.z += pushZ;
    this.plantFeet(avatar);
    syncColliderToRoot(avatar.collider, avatar.root);
    if (avatar.crowdAgent && this.officeCrowd) {
      // Keep Detour's copy of the position in step, or it will yank the agent
      // back to where it thought the body was on the next update.
      crowdTeleport(
        avatar.crowdAgent,
        this.officeCrowd.query,
        avatar.root.position.x,
        avatar.root.position.z,
      );
    }
  }

  private pauseCrowdAgent(avatar: AvatarNode) {
    avatar.crowdAgent?.resetMoveTarget();
    avatar.crowdTargetKey = null;
  }

  /** Issue a crowd goto in centered scene space (idempotent per target). */
  private crowdGoTo(avatar: AvatarNode, x: number, z: number) {
    if (!this.officeCrowd || !avatar.crowdAgent) return false;
    const key = `${x.toFixed(2)},${z.toFixed(2)}`;
    if (avatar.crowdTargetKey === key) return true;
    crowdGoto(avatar.crowdAgent, this.officeCrowd.query, x, z);
    avatar.crowdTargetKey = key;
    // Do NOT reset noMoveTimer here — retargeting while stuck must still escape.
    return true;
  }

  /**
   * Sync Babylon root from crowd agent. Returns true when the agent has
   * reached its current move target.
   */
  private syncFromCrowd(avatar: AvatarNode, dt: number, reach = 0.4): boolean {
    const agent = avatar.crowdAgent;
    if (!agent || !this.officeCrowd) return false;

    // Always read live Detour position() — interpolatedPosition can stale-freeze
    // while velocity still reports motion (walking-in-place bug).
    const p = agent.position();
    avatar.root.position.x = p.x;
    avatar.root.position.z = p.z;
    this.plantFeet(avatar);
    syncColliderToRoot(avatar.collider, avatar.root);

    // Trust the navmesh. Only recover on Detour invalid state or true immobility.
    // Do NOT use padded furniture AABBs here — they thrash recover in narrow aisles.
    if (crowdAgentIsStuck(agent) || this.tickImmobile(avatar, dt)) {
      this.recoverCrowdAgent(avatar);
      return false;
    }

    const speed = crowdSpeed(agent);
    const vel = agent.velocity();
    if (speed > CROWD_MOVE_EPS) {
      // Steer by a smoothed heading: raw Detour velocity jitters as obstacle
      // avoidance nudges it, and feeding that straight into rotation.y made
      // avatars twitch and appear to slide sideways through their own turn.
      const target = Math.atan2(vel.x, vel.z);
      avatar.headingFilter = avatar.headingFilter ?? target;
      let delta = target - avatar.headingFilter;
      while (delta > Math.PI) delta -= Math.PI * 2;
      while (delta < -Math.PI) delta += Math.PI * 2;
      // Time-correct exponential smoothing (frame-rate independent).
      const alpha = 1 - Math.exp(-dt / OfficeScene.HEADING_TAU);
      avatar.headingFilter += delta * alpha;
      this.turnToward(avatar, avatar.headingFilter, dt);
      playAgentAnimation(avatar, "walking");
      this.reportActivity(avatar, "walking");
    } else {
      avatar.headingFilter = avatar.facing;
      playAgentAnimation(avatar, "idle");
      // Clear stale "Walking" labels while standing still.
      if (avatar.reportedActivity === "walking") this.reportActivity(avatar, null);
    }

    let target: { x: number; z: number };
    try {
      target = agent.target();
    } catch {
      return false;
    }
    const dist = Math.hypot(target.x - p.x, target.z - p.z);
    return dist < reach && speed < CROWD_MOVE_EPS * 1.5;
  }

  private recoverCrowdAgent(avatar: AvatarNode) {
    const now = performance.now();
    if (now < avatar.recoverUntil) return;
    avatar.recoverUntil = now + 2500;

    if (!this.officeCrowd || !avatar.crowdAgent) {
      this.escapeToAisle(avatar);
      return;
    }
    const fromRaw = {
      x: avatar.root.position.x + this.centerOffset.x,
      z: avatar.root.position.z + this.centerOffset.z,
    };
    const safe = nearestAislePoint(fromRaw);
    const jig = ((avatar.seatIndex % 5) - 2) * 0.18;
    const centered = crowdClosestPoint(
      this.officeCrowd.query,
      safe.x + jig - this.centerOffset.x,
      safe.z - this.centerOffset.z,
    );
    crowdTeleport(avatar.crowdAgent, this.officeCrowd.query, centered.x, centered.z);
    avatar.root.position.x = centered.x;
    avatar.root.position.z = centered.z;
    this.plantFeet(avatar);
    avatar.crowdTargetKey = null;
    avatar.noMoveTimer = 0;
    avatar.immobileAnchorX = centered.x;
    avatar.immobileAnchorZ = centered.z;
    avatar.stuckTimer = 0;
    if (import.meta.env.DEV) {
      console.info("[OfficeScene] crowd recover → aisle", avatar.agent.name, centered);
    }
    // Re-issue mission from the safe point.
    if (avatar.idleBehavior === "poi") this.beginPoiRoute(avatar);
    else if (avatar.deskRouteBusy || avatar.idleBehavior === "desk_sit") {
      this.beginDeskSitRoute(avatar, avatar.pendingDeskState ?? "working");
    } else this.assignPatrolLane(avatar);
  }

  /** Follow pre-traced paths; pause at waypoints; honor server POI assignments. */
  private animateIdle(avatar: AvatarNode, t: number, dt: number) {
    if (avatar.agent.officePoiId && avatar.agent.officeSlotId && !avatar.routeBusy) {
      if (avatar.idleBehavior !== "poi") {
        this.beginPoiRoute(avatar);
      }
    }

    if (avatar.idleBehavior === "poi") {
      this.animatePoi(avatar, t, dt);
      return;
    }

    if (avatar.idleBehavior !== "patrol") {
      playAgentAnimation(avatar, "idle");
      this.plantFeet(avatar);
      // Detour stops steering an agent once its move target is cleared, so two
      // agents that stop to scroll or stretch beside each other keep whatever
      // spacing they arrived with — which can be none. Keep them apart here.
      this.separateFromNeighbours(avatar);
      if (t >= avatar.behaviorEnd) {
        avatar.idleBehavior = "patrol";
        this.reportActivity(avatar, null);
        return;
      }
      this.playIdleActivity(avatar, t);
      return;
    }

    const wp = avatar.activePath.waypoints[avatar.pathIndex];
    if (!wp) {
      this.assignPatrolLane(avatar);
      return;
    }

    const arrived = this.moveAlongMission(avatar, wp.x, wp.z, 1.35, dt, 0.4);
    if (!arrived) return;

    playAgentAnimation(avatar, "idle");
    this.plantFeet(avatar);
    avatar.stuckTimer = 0;
    this.reportActivity(avatar, null);

    if (wp.activity) {
      avatar.idleBehavior = wp.activity;
      avatar.behaviorEnd = t + 4 + Math.random() * 5;
      this.reportActivity(
        avatar,
        wp.activity === "coffee"
          ? "preparing_coffee"
          : wp.activity === "playing"
            ? "playing_foosball"
            : wp.activity === "sitting"
              ? "sitting_sofa"
              : wp.activity === "scrolling"
                ? "scrolling"
                : wp.activity === "stretch"
                  ? "stretching"
                  : "looking_around",
      );
      return;
    }

    if (Math.random() < 0.2) {
      const pauses: IdleActivity[] = ["look", "scrolling", "stretch"];
      avatar.idleBehavior = pauses[Math.floor(Math.random() * pauses.length)];
      avatar.behaviorEnd = t + 3 + Math.random() * 4;
      this.reportActivity(
        avatar,
        avatar.idleBehavior === "scrolling"
          ? "scrolling"
          : avatar.idleBehavior === "stretch"
            ? "stretching"
            : "looking_around",
      );
      return;
    }

    avatar.pathIndex += 1;
    avatar.crowdTargetKey = null;
    if (avatar.pathIndex >= avatar.activePath.waypoints.length) {
      if (avatar.activePath.loop) avatar.pathIndex = 0;
      else this.assignPatrolLane(avatar);
    }
  }

  /**
   * Prefer Recast Crowd; fall back to single-authority resolveCollision walk.
   * Returns true when the destination is reached.
   */
  private moveAlongMission(
    avatar: AvatarNode,
    x: number,
    z: number,
    speed: number,
    dt: number,
    reach: number,
  ): boolean {
    this.attachCrowdAgent(avatar);
    if (avatar.crowdAgent && this.officeCrowd) {
      this.crowdGoTo(avatar, x, z);
      return this.syncFromCrowd(avatar, dt, reach);
    }
    const target = new Vector3(x, avatar.root.position.y, z);
    return this.walkToward(avatar, target, speed, dt);
  }

  /** Assign (or re-assign) the seat-exclusive patrol loop. */
  private assignPatrolLane(avatar: AvatarNode) {
    const path = pathForSeat(avatar.seatIndex, this.paths);
    avatar.activePath = path;
    avatar.pathIndex = staggeredWaypointIndex(
      path,
      avatar.root.position.x,
      avatar.root.position.z,
      avatar.seatIndex,
    );
    avatar.stuckTimer = 0;
    avatar.lastProgressDist = Infinity;
    avatar.crowdTargetKey = null;
    avatar.noMoveTimer = 0;
  }

  /** Last POI slot this avatar committed to (re-route when server reassigns). */
  private lastPoiKey = new Map<string, string>();

  private syncServerActivity(avatar: AvatarNode) {
    const agent = avatar.agent;
    if (!isIdleVisual(agent.visualState)) return;
    // Drive POI from slot assignment — not from secondaryActivity, which the
    // React layer may rewrite to "walking" while approaching.
    if (agent.officePoiId && agent.officeSlotId) {
      const key = `${agent.officePoiId}:${agent.officeSlotId}`;
      const prev = this.lastPoiKey.get(agent.id);
      if (avatar.idleBehavior !== "poi" || prev !== key) {
        this.lastPoiKey.set(agent.id, key);
        this.beginPoiRoute(avatar);
      }
    } else if (avatar.idleBehavior === "poi" && !agent.officePoiId) {
      this.lastPoiKey.delete(agent.id);
      avatar.idleBehavior = "patrol";
      avatar.routeBusy = false;
      this.standFromSocket(avatar);
      this.reportActivity(avatar, null);
      this.returnHome(avatar);
    }
  }

  /** Prefer mesh-calibrated sockets when available. */
  private resolveSocket(slotId: string): SeatSocket | null {
    return this.socketOverrides.get(slotId) ?? poiSlotSocket(slotId);
  }

  /**
   * Claim a POI slot for one agent.
   *
   * The server assigns POI slots, but two agents can legitimately hold the
   * same slot for a few frames (reassignment races, reconnects). Without an
   * exclusive claim they walk into the same socket and the hold logic pins
   * both to identical coordinates, which reads as two bodies merged into one.
   * Returns false when another live agent already owns the slot.
   */
  private claimSlot(avatar: AvatarNode, slotId: string): boolean {
    const owner = this.slotClaims.get(slotId);
    if (owner && owner !== avatar.agent.id && this.avatars.has(owner)) return false;
    // Release whatever this agent held before (slot changed server-side).
    if (avatar.claimedSlotId && avatar.claimedSlotId !== slotId) {
      this.releaseSlot(avatar);
    }
    this.slotClaims.set(slotId, avatar.agent.id);
    avatar.claimedSlotId = slotId;
    return true;
  }

  private releaseSlot(avatar: AvatarNode) {
    const held = avatar.claimedSlotId;
    if (!held) return;
    if (this.slotClaims.get(held) === avatar.agent.id) this.slotClaims.delete(held);
    avatar.claimedSlotId = null;
  }

  /**
   * Report drift between the authored foosball table AABB and the mesh that
   * actually shipped in the GLB.
   *
   * This used to *rewrite* the two stand sockets from the mesh bounds, putting
   * players at the north and south ends. Recast erodes the floor mesh by the
   * agent radius and the north strip is too thin to keep a navmesh polygon, so
   * the second player could never arrive and looped in crowd-recover forever.
   * The authored sockets are navmesh-verified (office-crowd.test.ts), so they
   * win; a mismatch here means the GLB moved and the data needs re-measuring.
   */
  private checkFoosballTableDrift() {
    const tables = this.debugMeshBounds("soccer|foosball").filter((t) => {
      const w = t.max.x - t.min.x;
      const d = t.max.z - t.min.z;
      return w > 0.45 && w < 2.8 && d > 0.45 && d < 2.8;
    });
    if (!tables.length) return;

    const t = tables[0];
    const driftX = Math.abs((t.min.x + t.max.x) / 2 - (FOOSBALL_TABLE_AABB.minX + FOOSBALL_TABLE_AABB.maxX) / 2);
    const driftZ = Math.abs((t.min.z + t.max.z) / 2 - (FOOSBALL_TABLE_AABB.minZ + FOOSBALL_TABLE_AABB.maxZ) / 2);
    if (driftX > FOOSBALL_STAND_GAP || driftZ > FOOSBALL_STAND_GAP) {
      console.warn(
        `[OfficeScene] foosball table moved in the GLB (drift ${driftX.toFixed(2)}m x, ` +
          `${driftZ.toFixed(2)}m z) — re-measure FOOSBALL_TABLE_AABB and the player spots`,
      );
    }
  }

  /** Navmesh-reachable approach for a POI (aisle), not the seat inside furniture. */
  private poiCrowdDest(poi: NonNullable<ReturnType<typeof poiById>>, socket: SeatSocket): {
    x: number;
    z: number;
  } {
    const approach = poi.approach[0] ?? socket.position;
    if (this.officeCrowd) {
      return crowdNavTarget(
        this.officeCrowd.query,
        approach.x,
        approach.z,
        this.centerOffset,
      );
    }
    return this.toCentered(approach.x, approach.z);
  }

  private beginPoiRoute(avatar: AvatarNode) {
    const poi = poiById(avatar.agent.officePoiId ?? "");
    const slot = poi?.slots.find((s) => s.id === avatar.agent.officeSlotId);
    const socket = slot ? this.resolveSocket(slot.id) : null;
    if (!poi || !slot || !socket) return;

    // Someone else is already using this exact spot — roam instead of
    // stacking two bodies on one socket.
    if (!this.claimSlot(avatar, slot.id)) {
      this.assignPatrolLane(avatar);
      return;
    }

    this.standFromSocket(avatar);
    this.attachCrowdAgent(avatar);
    const socketCentered = this.toCentered(socket.position.x, socket.position.z);
    const navDest = this.poiCrowdDest(poi, socket);
    const distSocket = Math.hypot(
      avatar.root.position.x - socketCentered.x,
      avatar.root.position.z - socketCentered.z,
    );
    const distNav = Math.hypot(avatar.root.position.x - navDest.x, avatar.root.position.z - navDest.z);
    const alreadyThere = distSocket < 0.55 || distNav < 0.45;

    avatar.idleBehavior = "poi";
    avatar.behaviorEnd = 0;
    avatar.stuckTimer = 0;
    avatar.lastProgressDist = Infinity;
    avatar.crowdTargetKey = null;
    this.reportActivity(avatar, "walking");
    playAgentAnimation(avatar, "walking");

    if (alreadyThere) {
      avatar.routeBusy = false;
      avatar.activePath = { id: `poi-${poi.id}-${slot.id}`, loop: false, waypoints: [] };
      avatar.pathIndex = 0;
      this.pauseCrowdAgent(avatar);
      this.blendToSocket(avatar, socket, this.poiAnimForSlot(slot.animation), 0.35);
      return;
    }

    // Crowd walks to the aisle approach; socket blend handles the last meters.
    avatar.activePath = {
      id: `poi-${poi.id}-${slot.id}`,
      loop: false,
      waypoints: [{ x: navDest.x, z: navDest.z }],
    };
    avatar.pathIndex = 0;
    avatar.routeBusy = true;
    if (avatar.crowdAgent && this.officeCrowd) {
      this.crowdGoTo(avatar, navDest.x, navDest.z);
    }
  }

  private poiAnimForSlot(animation: SecondaryActivity): AgentAnimName | string {
    if (animation === "sitting_sofa") return "sitting";
    if (animation === "playing_foosball") return "playing_foosball";
    if (animation === "preparing_coffee") return "preparing_coffee";
    return "idle";
  }

  private animatePoi(avatar: AvatarNode, t: number, dt: number) {
    const poi = poiById(avatar.agent.officePoiId ?? "");
    const slot = poi?.slots.find((s) => s.id === avatar.agent.officeSlotId);
    const socket = slot ? this.resolveSocket(slot.id) : null;
    if (!poi || !slot || !socket) {
      avatar.idleBehavior = "patrol";
      avatar.routeBusy = false;
      return;
    }

    if (avatar.socketBlend) return;

    const dest = this.toCentered(socket.position.x, socket.position.z);
    const distToSocket = Math.hypot(
      avatar.root.position.x - dest.x,
      avatar.root.position.z - dest.z,
    );

    // Only hold POI pose when physically at the socket — never in the aisle.
    if (avatar.socketLocked && avatar.socketId === socket.id) {
      if (distToSocket > 0.85) {
        avatar.socketLocked = false;
        avatar.socketId = null;
        setAgentCollisionsEnabled(avatar.collider, !avatar.crowdAgent);
        this.beginPoiRoute(avatar);
        return;
      }
      this.holdPoiSocket(avatar, socket, slot.animation, t);
      this.reportActivity(avatar, slot.animation);
      return;
    }

    // Crowd goes to the aisle approach (navmesh), then we blend into the socket.
    if (avatar.crowdAgent && this.officeCrowd) {
      const navDest = this.poiCrowdDest(poi, socket);
      this.crowdGoTo(avatar, navDest.x, navDest.z);
      const distNav = Math.hypot(
        avatar.root.position.x - navDest.x,
        avatar.root.position.z - navDest.z,
      );
      const arrived = this.syncFromCrowd(avatar, dt, 0.5);
      if (distToSocket < 0.7 || distNav < 0.55 || arrived) {
        avatar.routeBusy = false;
        avatar.stuckTimer = 0;
        this.pauseCrowdAgent(avatar);
        this.blendToSocket(avatar, socket, this.poiAnimForSlot(slot.animation), 0.4);
      }
      return;
    }

    const wp = avatar.activePath.waypoints[avatar.pathIndex];
    if (avatar.routeBusy && wp) {
      const allowEnter = Boolean(socket.sits && distToSocket < 0.95);
      const arrived = this.walkToward(
        avatar,
        new Vector3(wp.x, avatar.root.position.y, wp.z),
        1.45,
        dt,
        allowEnter,
      );

      if (distToSocket < 0.5) {
        avatar.routeBusy = false;
        avatar.stuckTimer = 0;
        this.blendToSocket(avatar, socket, this.poiAnimForSlot(slot.animation), 0.4);
        return;
      }

      if (arrived) {
        avatar.pathIndex += 1;
        if (avatar.pathIndex >= avatar.activePath.waypoints.length) {
          avatar.routeBusy = false;
          if (distToSocket < 1.1) {
            this.blendToSocket(avatar, socket, this.poiAnimForSlot(slot.animation), 0.45);
          } else {
            this.beginPoiRoute(avatar);
          }
        }
      }
      return;
    }

    this.beginPoiRoute(avatar);
  }

  /** Micro-sway / hold once the socket blend has finished at the real spot. */
  private holdPoiSocket(
    avatar: AvatarNode,
    socket: SeatSocket,
    animation: SecondaryActivity,
    t: number,
  ) {
    avatar.ring.setEnabled(false);
    avatar.root.rotation.x = 0;
    avatar.root.rotation.z = 0;
    // Pin XZ to the socket every frame so separation cannot drift them away.
    const dest = this.toCentered(socket.position.x, socket.position.z);
    avatar.root.position.x = dest.x;
    avatar.root.position.z = dest.z;

    if (animation === "playing_foosball") {
      playAgentAnimation(avatar, "playing_foosball" as AgentAnimName);
      this.plantFeet(avatar);
      avatar.root.rotation.y = socket.facing + Math.sin(t * 3.2 + avatar.phase) * 0.06;
      avatar.facing = avatar.root.rotation.y;
    } else if (animation === "preparing_coffee") {
      playAgentAnimation(avatar, "preparing_coffee" as AgentAnimName);
      this.plantFeet(avatar);
      avatar.root.rotation.y = socket.facing + Math.sin(t * 1.4 + avatar.phase) * 0.04;
      avatar.facing = avatar.root.rotation.y;
    } else if (animation === "sitting_sofa") {
      playAgentAnimation(avatar, "sitting" as AgentAnimName);
      const seatY = (socket.seatHeight || 0.48) - this.centerOffset.y;
      avatar.root.position.y = seatY - avatar.sitPelvisHeight;
      avatar.baseY = avatar.root.position.y;
      avatar.root.rotation.y = socket.facing;
      avatar.facing = socket.facing;
    } else {
      playAgentAnimation(avatar, "idle");
      this.plantFeet(avatar);
    }
    syncColliderToRoot(avatar.collider, avatar.root);
  }

  /** Walk quickly to the desk chair then blend into the seat socket. */
  private beginDeskSitRoute(avatar: AvatarNode, state: AgentAnimName | string) {
    // Heading back to the desk frees whatever lounge/foosball spot was held.
    this.releaseSlot(avatar);
    avatar.pendingDeskState = state;
    avatar.deskRouteBusy = true;
    avatar.idleBehavior = "desk_sit";
    avatar.routeBusy = true;
    avatar.socketLocked = false;
    avatar.socketId = null;
    avatar.crowdTargetKey = null;
    this.attachCrowdAgent(avatar);

    const dist = Math.hypot(
      avatar.root.position.x - avatar.homePos.x,
      avatar.root.position.z - avatar.homePos.z,
    );
    if (dist < 0.4) {
      avatar.deskRouteBusy = false;
      avatar.routeBusy = false;
      this.pauseCrowdAgent(avatar);
      const socket = deskSocket(avatar.seatIndex);
      if (socket) this.blendToSocket(avatar, socket, state, 0.35);
      else this.snapToDeskSocket(avatar, state);
      return;
    }

    // Fallback path if crowd is unavailable.
    if (!avatar.crowdAgent) {
      setAgentCollisionsEnabled(avatar.collider, true);
      const fromRaw = {
        x: avatar.root.position.x + this.centerOffset.x,
        z: avatar.root.position.z + this.centerOffset.z,
      };
      const deskRaw = {
        x: avatar.homePos.x + this.centerOffset.x,
        z: avatar.homePos.z + this.centerOffset.z,
      };
      const pathPts = routeToDesk(fromRaw, avatar.seatIndex, deskRaw, null).map((p) => ({
        x: p.x - this.centerOffset.x,
        z: p.z - this.centerOffset.z,
      }));
      avatar.activePath = {
        id: `desk-sit-${avatar.agent.id}`,
        loop: false,
        waypoints: pathPts.length > 1 ? pathPts : [{ x: avatar.homePos.x, z: avatar.homePos.z }],
      };
      avatar.pathIndex = 0;
    }

    avatar.stuckTimer = 0;
    avatar.lastProgressDist = Infinity;
    this.reportActivity(avatar, "walking");
    playAgentAnimation(avatar, "walking");
  }

  private animateDeskSit(avatar: AvatarNode, _t: number, dt: number) {
    if (avatar.socketBlend) return;
    if (!avatar.deskRouteBusy) {
      const socket = deskSocket(avatar.seatIndex);
      if (socket && !avatar.socketLocked) {
        this.blendToSocket(avatar, socket, avatar.pendingDeskState ?? "working", 0.4);
      }
      return;
    }

    if (avatar.crowdAgent && this.officeCrowd) {
      // Chair sits inside a desk AABB — walk to nearest navmesh point, then blend in.
      const nav = crowdNavTarget(
        this.officeCrowd.query,
        avatar.homePos.x + this.centerOffset.x,
        avatar.homePos.z + this.centerOffset.z,
        this.centerOffset,
      );
      this.crowdGoTo(avatar, nav.x, nav.z);
      const distNav = Math.hypot(
        avatar.root.position.x - nav.x,
        avatar.root.position.z - nav.z,
      );
      const distHome = Math.hypot(
        avatar.root.position.x - avatar.homePos.x,
        avatar.root.position.z - avatar.homePos.z,
      );
      const arrived = this.syncFromCrowd(avatar, dt, 0.45);
      if (arrived || distNav < 0.5 || distHome < 0.65) {
        avatar.deskRouteBusy = false;
        avatar.routeBusy = false;
        this.pauseCrowdAgent(avatar);
        const socket = deskSocket(avatar.seatIndex);
        if (socket) this.blendToSocket(avatar, socket, avatar.pendingDeskState ?? "working", 0.4);
        else this.snapToDeskSocket(avatar, avatar.pendingDeskState ?? "working");
      }
      return;
    }

    const wp = avatar.activePath.waypoints[avatar.pathIndex];
    if (!wp) {
      avatar.deskRouteBusy = false;
      avatar.routeBusy = false;
      const socket = deskSocket(avatar.seatIndex);
      if (socket) this.blendToSocket(avatar, socket, avatar.pendingDeskState ?? "working", 0.4);
      return;
    }

    const lastLeg = avatar.pathIndex >= avatar.activePath.waypoints.length - 1;
    const arrived = this.walkToward(
      avatar,
      new Vector3(wp.x, avatar.root.position.y, wp.z),
      2.2,
      dt,
      lastLeg,
    );
    if (arrived) {
      avatar.pathIndex += 1;
      if (avatar.pathIndex >= avatar.activePath.waypoints.length) {
        avatar.deskRouteBusy = false;
        avatar.routeBusy = false;
        const socket = deskSocket(avatar.seatIndex);
        if (socket) this.blendToSocket(avatar, socket, avatar.pendingDeskState ?? "working", 0.4);
        else this.snapToDeskSocket(avatar, avatar.pendingDeskState ?? "working");
      }
    }
  }

  /** Immediate seat (spawn / already at desk) — no blend. */
  private snapToDeskSocket(avatar: AvatarNode, state: AgentAnimName | string) {
    const socket = deskSocket(avatar.seatIndex);
    if (!socket) return;
    setAgentCollisionsEnabled(avatar.collider, false);
    const dest = this.toCentered(socket.position.x, socket.position.z);
    avatar.root.position.x = dest.x;
    avatar.root.position.z = dest.z;
    avatar.root.rotation.x = 0;
    avatar.root.rotation.z = 0;
    avatar.root.rotation.y = socket.facing;
    avatar.facing = socket.facing;
    const seatY = socket.seatHeight - this.centerOffset.y;
    avatar.root.position.y = seatY - avatar.sitPelvisHeight;
    avatar.baseY = avatar.root.position.y;
    avatar.socketLocked = true;
    avatar.socketId = socket.id;
    avatar.ring.setEnabled(true);
    playAgentAnimation(avatar, state as AgentAnimName);
    syncColliderToRoot(avatar.collider, avatar.root);
    this.reportActivity(avatar, null);
  }

  /**
   * Smoothly transition into a seat/stand socket: disable collisions, lerp
   * position + yaw, then lock and play the target animation.
   */
  private blendToSocket(
    avatar: AvatarNode,
    socket: SeatSocket,
    anim: AgentAnimName | string,
    duration = 0.45,
  ) {
    this.pauseCrowdAgent(avatar);
    setAgentCollisionsEnabled(avatar.collider, false);
    const dest = this.toCentered(socket.position.x, socket.position.z);
    const toY = socket.sits
      ? (socket.seatHeight || 0.48) - this.centerOffset.y - avatar.sitPelvisHeight
      : floorYAt(dest.x, dest.z) + avatar.footOffset;

    avatar.socketBlend = {
      fromX: avatar.root.position.x,
      fromZ: avatar.root.position.z,
      fromY: avatar.root.position.y,
      fromYaw: avatar.facing,
      toX: dest.x,
      toZ: dest.z,
      toY,
      toYaw: socket.facing,
      start: performance.now() / 1000,
      duration,
      anim,
      socketId: socket.id,
      sits: socket.sits,
    };
    avatar.socketLocked = false;
    avatar.socketId = null;
    avatar.ring.setEnabled(socket.kind === "desk");
    // Keep walking until we are nearly at the socket — avoids foosball pose in the aisle.
    playAgentAnimation(avatar, "walking");
    this.reportActivity(avatar, "walking");
  }

  private tickSocketBlend(avatar: AvatarNode, t: number) {
    const blend = avatar.socketBlend;
    if (!blend) return;
    const u = Math.min(1, (t - blend.start) / Math.max(0.05, blend.duration));
    const s = u * u * (3 - 2 * u); // smoothstep
    avatar.root.position.x = blend.fromX + (blend.toX - blend.fromX) * s;
    avatar.root.position.z = blend.fromZ + (blend.toZ - blend.fromZ) * s;
    avatar.root.position.y = blend.fromY + (blend.toY - blend.fromY) * s;

    let dyaw = blend.toYaw - blend.fromYaw;
    const twoPi = Math.PI * 2;
    dyaw = ((dyaw + Math.PI) % twoPi + twoPi) % twoPi - Math.PI;
    avatar.facing = blend.fromYaw + dyaw * s;
    avatar.root.rotation.y = avatar.facing;
    avatar.root.rotation.x = 0;
    avatar.root.rotation.z = 0;
    syncColliderToRoot(avatar.collider, avatar.root);

    // Switch to the target clip only when close to the socket.
    if (u >= 0.85) {
      playAgentAnimation(
        avatar,
        (blend.sits ? "sitting" : blend.anim) as AgentAnimName,
      );
    } else {
      playAgentAnimation(avatar, "walking");
      this.reportActivity(avatar, "walking");
    }

    if (u < 1) return;

    avatar.socketBlend = null;
    avatar.socketLocked = true;
    avatar.socketId = blend.socketId;
    avatar.root.position.x = blend.toX;
    avatar.root.position.z = blend.toZ;
    avatar.root.position.y = blend.toY;
    avatar.baseY = blend.toY;
    avatar.facing = blend.toYaw;
    avatar.root.rotation.y = blend.toYaw;
    playAgentAnimation(avatar, blend.anim as AgentAnimName);

    const slot = avatar.agent.officeSlotId
      ? poiById(avatar.agent.officePoiId ?? "")?.slots.find((s) => s.id === avatar.agent.officeSlotId)
      : null;
    if (slot?.animation) this.reportActivity(avatar, slot.animation);
    else this.reportActivity(avatar, null);
  }

  /** Leave a socket; crowd agents stay on navmesh (no ellipsoid furniture checks). */
  private standFromSocket(avatar: AvatarNode) {
    avatar.socketBlend = null;
    if (!avatar.socketLocked && !avatar.crowdAgent && avatar.collider.checkCollisions) return;
    avatar.socketLocked = false;
    avatar.socketId = null;
    // Crowd owns loco → keep collisions off. Fallback A* needs them on.
    setAgentCollisionsEnabled(avatar.collider, !avatar.crowdAgent);
    avatar.ring.setEnabled(true);
    this.plantFeet(avatar);
    syncColliderToRoot(avatar.collider, avatar.root);
  }

  private returnHome(avatar: AvatarNode) {
    this.releaseSlot(avatar);
    this.standFromSocket(avatar);
    avatar.root.rotation.x = 0;
    avatar.root.rotation.z = 0;
    avatar.ring.setEnabled(true);
    this.plantFeet(avatar);
    playAgentAnimation(avatar, "walking");
    const fromRaw = {
      x: avatar.root.position.x + this.centerOffset.x,
      z: avatar.root.position.z + this.centerOffset.z,
    };
    const deskRaw = {
      x: avatar.homePos.x + this.centerOffset.x,
      z: avatar.homePos.z + this.centerOffset.z,
    };
    const pathPts = routeToDesk(
      fromRaw,
      avatar.seatIndex,
      deskRaw,
      avatar.agent.officeSlotId,
    ).map((p) => ({ x: p.x - this.centerOffset.x, z: p.z - this.centerOffset.z }));
    avatar.activePath = { id: `home-${avatar.agent.id}`, loop: false, waypoints: pathPts };
    avatar.pathIndex = 0;
    avatar.idleBehavior = "patrol";
    avatar.routeBusy = false;
    avatar.stuckTimer = 0;
    avatar.lastProgressDist = Infinity;
    this.reportActivity(avatar, "walking");
  }

  private toCentered(x: number, z: number) {
    return { x: x - this.centerOffset.x, z: z - this.centerOffset.z };
  }

  private playIdleActivity(avatar: AvatarNode, t: number) {
    const { root, phase } = avatar;
    switch (avatar.idleBehavior) {
      case "coffee":
        root.rotation.y = Math.PI * 0.2;
        root.position.y = avatar.footOffset + Math.sin((t + phase) * 2) * 0.01;
        break;
      case "scrolling":
        root.rotation.y = Math.sin((t + phase) * 0.25) * 0.2;
        this.plantFeet(avatar);
        break;
      case "stretch":
        root.rotation.y = Math.sin((t + phase) * 0.4) * 0.1;
        root.position.y = avatar.footOffset + Math.sin((t + phase) * 1.5) * 0.02;
        break;
      case "look":
        root.rotation.y = Math.sin((t + phase) * 0.5) * 0.8;
        this.plantFeet(avatar);
        break;
      default:
        this.plantFeet(avatar);
        break;
    }
    avatar.facing = root.rotation.y;
  }

  /** Turn radians/sec while pivoting on the spot before stepping forward. */
  private static readonly TURN_SPEED = Math.PI * 2.4;
  /** Heading low-pass time constant (s). ~90 ms keeps turns snappy but stable. */
  private static readonly HEADING_TAU = 0.09;
  private static readonly SEPARATION = AGENT_RADIUS * 2.05;
  private static readonly STUCK_SECONDS = 1.5;
  /** Reset immobility anchor only after this much real travel (m). */
  private static readonly IMMOBILE_ANCHOR_R = 0.55;
  /** Yank to nearest aisle after this many seconds near the anchor. */
  private static readonly NO_MOVE_ESCAPE = 2.4;

  /**
   * Fallback step when Recast Crowd is unavailable.
   * Single collision authority: resolveCollision only (no moveWithCollisions
   * double-resolve — that jitter was resetting stuck timers forever).
   */
  private walkToward(
    avatar: AvatarNode,
    target: Vector3,
    speed: number,
    dt: number,
    allowEnterObstacle = false,
  ): boolean {
    const pos = avatar.root.position;
    let dx = target.x - pos.x;
    let dz = target.z - pos.z;

    const rawTarget = {
      x: target.x + this.centerOffset.x,
      z: target.z + this.centerOffset.z,
    };

    let sepDx = 0;
    let sepDz = 0;
    for (const other of this.avatars.values()) {
      if (other === avatar) continue;
      const ox = pos.x - other.root.position.x;
      const oz = pos.z - other.root.position.z;
      const d2 = ox * ox + oz * oz;
      const minD = OfficeScene.SEPARATION;
      if (d2 > 1e-6 && d2 < minD * minD) {
        const d = Math.sqrt(d2);
        const push = ((minD - d) / d) * 0.55;
        sepDx += ox * push;
        sepDz += oz * push;
      }
    }
    if (sepDx !== 0 || sepDz !== 0) {
      const trialRaw = {
        x: pos.x + dx + sepDx + this.centerOffset.x,
        z: pos.z + dz + sepDz + this.centerOffset.z,
      };
      if (allowEnterObstacle || isWalkable(trialRaw)) {
        dx += sepDx;
        dz += sepDz;
      }
    }

    const dist = Math.sqrt(dx * dx + dz * dz);
    if (dist < 0.22) {
      if (allowEnterObstacle || isWalkable(rawTarget)) {
        pos.x = target.x;
        pos.z = target.z;
        this.plantFeet(avatar);
        syncColliderToRoot(avatar.collider, avatar.root);
        avatar.stuckTimer = 0;
        avatar.noMoveTimer = 0;
        return true;
      }
      // Unreachable waypoint — skip instead of moonwalking.
      avatar.pathIndex += 1;
      avatar.stuckTimer = 0;
      return false;
    }

    if (dist < avatar.lastProgressDist - 0.02) {
      avatar.stuckTimer = 0;
      avatar.lastProgressDist = dist;
    } else {
      avatar.stuckTimer += dt;
      if (avatar.stuckTimer >= OfficeScene.STUCK_SECONDS) {
        avatar.stuckTimer = 0;
        avatar.lastProgressDist = Infinity;
        this.escapeToAisle(avatar);
        return false;
      }
    }

    if (this.tickImmobile(avatar, dt)) {
      this.escapeToAisle(avatar);
      return false;
    }

    const heading = Math.atan2(dx, dz);
    const turnAlign = this.turnToward(avatar, heading, dt);
    avatar.root.rotation.x = 0;
    avatar.root.rotation.z = 0;

    const beforeX = pos.x;
    const beforeZ = pos.z;
    // Only brake for genuinely sharp turns. turnAlign maps yaw error over the
    // full ±π, so the old 0.35 + 0.65·align curve slowed agents to a crawl for
    // routine course corrections. Full speed once we are within ~50°.
    const moveScale = 0.55 + 0.45 * Math.min(1, turnAlign / 0.72);
    const step = Math.min(speed * dt * moveScale, dist);
    const stepX = (dx / dist) * step;
    const stepZ = (dz / dist) * step;

    if (allowEnterObstacle) {
      pos.x += stepX;
      pos.z += stepZ;
    } else {
      const trial = resolveCollision(
        {
          x: pos.x + stepX + this.centerOffset.x,
          z: pos.z + stepZ + this.centerOffset.z,
        },
        OFFICE_OBSTACLES,
        AGENT_RADIUS,
      );
      const raw = resolveCollision(trial, undefined, NAV_CLEARANCE);
      pos.x = raw.x - this.centerOffset.x;
      pos.z = raw.z - this.centerOffset.z;
    }
    this.plantFeet(avatar);
    syncColliderToRoot(avatar.collider, avatar.root);

    const moved = Math.hypot(pos.x - beforeX, pos.z - beforeZ);
    if (moved < 0.01) {
      playAgentAnimation(avatar, "idle");
      this.reportActivity(avatar, "walking");
    } else {
      playAgentAnimation(avatar, "walking");
      this.reportActivity(avatar, "walking");
    }
    return false;
  }

  /**
   * Immobility by anchor: ignore micro-jitter from collision slides.
   * Only resets when the agent travels > IMMOBILE_ANCHOR_R from the anchor.
   */
  private tickImmobile(avatar: AvatarNode, dt: number): boolean {
    const x = avatar.root.position.x;
    const z = avatar.root.position.z;
    const fromAnchor = Math.hypot(x - avatar.immobileAnchorX, z - avatar.immobileAnchorZ);
    if (fromAnchor > OfficeScene.IMMOBILE_ANCHOR_R) {
      avatar.immobileAnchorX = x;
      avatar.immobileAnchorZ = z;
      avatar.noMoveTimer = 0;
      return false;
    }
    avatar.noMoveTimer += dt;
    return avatar.noMoveTimer >= OfficeScene.NO_MOVE_ESCAPE;
  }

  /** Teleport out of a dead-end pinch onto the nearest open aisle anchor. */
  private escapeToAisle(avatar: AvatarNode) {
    const fromRaw = {
      x: avatar.root.position.x + this.centerOffset.x,
      z: avatar.root.position.z + this.centerOffset.z,
    };
    const safe = nearestAislePoint(fromRaw);
    // Slight seat-based offset so two stuck agents don't re-stack on the same cell.
    const jig = ((avatar.seatIndex % 5) - 2) * 0.18;
    const dest = resolveCollision(
      { x: safe.x + jig, z: safe.z },
      undefined,
      NAV_CLEARANCE,
    );
    avatar.root.position.x = dest.x - this.centerOffset.x;
    avatar.root.position.z = dest.z - this.centerOffset.z;
    this.plantFeet(avatar);
    syncColliderToRoot(avatar.collider, avatar.root);
    avatar.noMoveTimer = 0;
    avatar.stuckTimer = 0;
    avatar.lastProgressDist = Infinity;
    avatar.immobileAnchorX = avatar.root.position.x;
    avatar.immobileAnchorZ = avatar.root.position.z;
    avatar.crowdTargetKey = null;
    if (avatar.crowdAgent && this.officeCrowd) {
      crowdTeleport(avatar.crowdAgent, this.officeCrowd.query, dest.x - this.centerOffset.x, dest.z - this.centerOffset.z);
    }

    if (import.meta.env.DEV) {
      console.info("[OfficeScene] escaped pinch → aisle", avatar.agent.name, dest);
    }

    if (avatar.idleBehavior === "poi") {
      this.beginPoiRoute(avatar);
    } else if (avatar.deskRouteBusy || avatar.idleBehavior === "desk_sit") {
      this.beginDeskSitRoute(avatar, avatar.pendingDeskState ?? "working");
    } else {
      this.assignPatrolLane(avatar);
    }
  }

  /** Plant feet exactly on the floor surface using footOffset + nav floor height. */
  private plantFeet(avatar: AvatarNode) {
    avatar.root.rotation.x = 0;
    avatar.root.rotation.z = 0;
    const y = floorYAt(avatar.root.position.x, avatar.root.position.z) + avatar.footOffset;
    avatar.root.position.y = y;
    avatar.baseY = y;
    syncColliderToRoot(avatar.collider, avatar.root);
  }

  private reportActivity(avatar: AvatarNode, activity: SecondaryActivity) {
    if (avatar.reportedActivity === activity) return;
    avatar.reportedActivity = activity;
    this.callbacks.onAgentActivity?.(avatar.agent.id, activity);
  }

  /**
   * Smoothly rotate the avatar toward `heading`.
   * Returns alignment factor 0..1 (1 = fully facing the target).
   */
  private turnToward(avatar: AvatarNode, heading: number, dt: number): number {
    const twoPi = Math.PI * 2;
    let delta = (heading - avatar.facing) % twoPi;
    if (delta > Math.PI) delta -= twoPi;
    if (delta < -Math.PI) delta += twoPi;

    const maxStep = OfficeScene.TURN_SPEED * dt;
    if (Math.abs(delta) <= maxStep) {
      avatar.facing = heading;
      delta = 0;
    } else {
      avatar.facing += Math.sign(delta) * maxStep;
    }

    avatar.root.rotation.y = avatar.facing;
    // Map remaining yaw error to a 0..1 alignment (π rad → 0).
    return Math.max(0, 1 - Math.abs(delta) / Math.PI);
  }

  /** Drop bloom / resolution when FPS stays low to keep the office responsive. */
  private adaptQuality() {
    const fps = this.engine.getFps();
    if (fps > 0 && fps < 40) this.lowFpsFrames += 1;
    else this.lowFpsFrames = Math.max(0, this.lowFpsFrames - 2);

    let next: RenderQuality = this.renderQuality;
    if (this.lowFpsFrames > 90) next = "low";
    else if (this.lowFpsFrames > 45) next = "medium";
    else if (fps > 55 && this.lowFpsFrames === 0) next = "high";
    if (next === this.renderQuality || !this.pipeline) return;
    this.renderQuality = next;

    if (next === "high") {
      this.pipeline.bloomEnabled = true;
      this.pipeline.bloomWeight = OFFICE_BLOOM.weight;
      this.pipeline.samples = 4;
      this.pipeline.fxaaEnabled = false;
      this.engine.setHardwareScalingLevel(this.baseScale);
    } else if (next === "medium") {
      this.pipeline.bloomEnabled = true;
      this.pipeline.bloomWeight = OFFICE_BLOOM.weight * 0.65;
      this.pipeline.samples = 2;
      this.pipeline.fxaaEnabled = false;
      this.engine.setHardwareScalingLevel(this.baseScale * 1.3);
    } else {
      this.pipeline.bloomEnabled = false;
      this.pipeline.samples = 1;
      this.pipeline.fxaaEnabled = true;
      this.engine.setHardwareScalingLevel(this.baseScale * 1.7);
    }
    this.lastClientW = 0;
    this.lastClientH = 0;
    this.engine.resize();
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
    if (cw === this.lastClientW && ch === this.lastClientH) return;
    this.lastClientW = cw;
    this.lastClientH = ch;
    // Engine.resize() respects adaptToDeviceRatio + hardwareScalingLevel.
    this.engine.resize();
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
    for (const avatar of this.avatars.values()) {
      this.detachCrowdAgent(avatar);
      avatar.collider.dispose();
    }
    this.avatars.clear();
    this.officeCrowd?.destroy();
    this.officeCrowd = null;
    disposeObstacleColliders(this.obstacleColliders);
    this.pipeline?.dispose();
    this.pipeline = null;
    for (const light of this.sceneLights) light.dispose();
    this.sceneLights = [];
    this.engine.stopRenderLoop();
    this.scene.dispose();
    this.engine.dispose();
  }
}

// Only truly unoccupied agents roam the office. "waiting" (approval pending)
// stays at the desk: an agent with work in flight must look like it.
/**
 * World-space centre of an avatar's drawn geometry. Used by the debug
 * snapshot to tell "the logic moved the agent" apart from "the body the
 * viewer sees actually moved".
 */
function meshCentre(avatar: AvatarNode): { x: number; z: number } | null {
  let minX = Infinity;
  let maxX = -Infinity;
  let minZ = Infinity;
  let maxZ = -Infinity;
  let found = false;
  for (const mesh of avatar.meshes) {
    if (!mesh.isEnabled()) continue;
    const bb = mesh.getBoundingInfo().boundingBox;
    minX = Math.min(minX, bb.minimumWorld.x);
    maxX = Math.max(maxX, bb.maximumWorld.x);
    minZ = Math.min(minZ, bb.minimumWorld.z);
    maxZ = Math.max(maxZ, bb.maximumWorld.z);
    found = true;
  }
  return found ? { x: (minX + maxX) / 2, z: (minZ + maxZ) / 2 } : null;
}

function isIdleVisual(state: string): boolean {
  return state === "idle" || state === "walking";
}
