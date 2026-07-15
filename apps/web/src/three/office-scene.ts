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
import {
  ENERGY_TO_INTENSITY_AREA,
  ENERGY_TO_INTENSITY_POINT,
  OFFICE_BLOOM,
  OFFICE_CAMERA,
  OFFICE_LIGHTS,
  type OfficeLightDef,
} from "./office-lighting";
import {
  nearestWaypointIndex,
  OFFICE_DESK_SLOTS,
  OFFICE_PATHS,
  pickPathNear,
  type IdleActivity,
  type OfficePath,
} from "./office-paths";
import {
  AGENT_RADIUS,
  findPath,
  floorYAt,
  MAX_OFFICE_SEATS,
  poiById,
  type SecondaryActivity,
} from "./office-navdata";
import type { SceneAgent, SceneCallbacks } from "./types";

type IdleBehavior = "patrol" | IdleActivity | "poi";

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
  /** Last secondary activity reported to React. */
  reportedActivity: SecondaryActivity;
  routeBusy: boolean;
}

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
  private renderQuality: RenderQuality = "high";
  private lowFpsFrames = 0;

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

    this.engine.runRenderLoop(() => {
      if (this.disposed) return;
      this.syncEngineSize();
      this.animate();
      this.scene.render();
      this.reportOverlay();
      this.adaptQuality();
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

    pipeline.imageProcessingEnabled = true;
    pipeline.imageProcessing.toneMappingEnabled = true;
    pipeline.imageProcessing.toneMappingType = ImageProcessingConfiguration.TONEMAPPING_ACES;
    pipeline.imageProcessing.exposure = 1.3;
    pipeline.imageProcessing.contrast = 1.08;
    pipeline.imageProcessing.vignetteEnabled = true;
    pipeline.imageProcessing.vignetteWeight = 1.4;
    pipeline.imageProcessing.vignetteColor = new Color4(0, 0, 0, 1);
    pipeline.fxaaEnabled = true;

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
        primaryShadow = new ShadowGenerator(1024, light);
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
      const result = await SceneLoader.ImportMeshAsync(
        "",
        url,
        "",
        this.scene,
        (event) => {
          if (!event.lengthComputable || event.total === 0) return;
          this.callbacks.onLoadProgress?.(Math.min(1, event.loaded / event.total));
        },
      );

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

      // Center footprint on XZ and plant the floor at y=0.
      root.computeWorldMatrix(true);
      const bi = root.getHierarchyBoundingVectors(true);
      const centerX = (bi.min.x + bi.max.x) / 2;
      const centerZ = (bi.min.z + bi.max.z) / 2;
      const minY = bi.min.y;
      root.position.set(-centerX, -minY, -centerZ);
      root.computeWorldMatrix(true);
      this.centerOffset = { x: centerX, y: minY, z: centerZ };

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
          this.plantFeet(existing);
          existing.idleBehavior = "patrol";
          existing.routeBusy = false;
          this.reportActivity(existing, null);
          playAgentAnimation(existing, "idle");
        } else if (!wasIdle && nowIdle) {
          existing.idleBehavior = "patrol";
          existing.behaviorEnd = 0;
          existing.activePath = pickPathNear(
            existing.root.position.x,
            existing.root.position.z,
            undefined,
            this.paths,
          );
          existing.pathIndex = nearestWaypointIndex(
            existing.activePath,
            existing.root.position.x,
            existing.root.position.z,
          );
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

    const slot = this.deskSlots[seatIndex] ?? Vector3.Zero();
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

    const path = pickPathNear(slot.x, slot.z, undefined, this.paths);
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
      reportedActivity: null,
      routeBusy: false,
    };

    this.avatars.set(agent.id, avatar);
    this.plantFeet(avatar);
    for (const mesh of spawned.meshes) {
      this.shadowGenerator?.addShadowCaster(mesh);
    }
    playAgentAnimation(avatar, "idle");
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
      this.plantFeet(avatar);
      if (state === "away" || state === "offline") {
        avatar.root.position.y = avatar.baseY;
      }

      avatar.facing = root.rotation.y;
      this.reportActivity(avatar, null);
    }
  }

  /** Follow pre-traced paths; pause at waypoints; honor server POI assignments. */
  private animateIdle(avatar: AvatarNode, t: number, dt: number) {
    const { root } = avatar;

    if (avatar.agent.secondaryActivity && avatar.agent.officePoiId && !avatar.routeBusy) {
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
      avatar.activePath = pickPathNear(root.position.x, root.position.z, avatar.activePath.id, this.paths);
      avatar.pathIndex = 0;
      return;
    }

    const target = new Vector3(wp.x, root.position.y, wp.z);
    const arrived = this.walkToward(avatar, target, 1.35, dt);
    this.reportActivity(avatar, arrived ? null : "walking");

    if (arrived) {
      playAgentAnimation(avatar, "idle");
      this.plantFeet(avatar);

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
      if (avatar.pathIndex >= avatar.activePath.waypoints.length) {
        if (avatar.activePath.loop) {
          avatar.pathIndex = 0;
        } else {
          avatar.activePath = pickPathNear(root.position.x, root.position.z, avatar.activePath.id, this.paths);
          avatar.pathIndex = 0;
        }
      }
    }
  }

  private syncServerActivity(avatar: AvatarNode) {
    const agent = avatar.agent;
    if (!isIdleVisual(agent.visualState)) return;
    if (agent.officePoiId && agent.officeSlotId && agent.secondaryActivity) {
      if (avatar.idleBehavior !== "poi" && !avatar.routeBusy) {
        this.beginPoiRoute(avatar);
      }
    } else if (avatar.idleBehavior === "poi" && !agent.officePoiId) {
      avatar.idleBehavior = "patrol";
      avatar.routeBusy = false;
      this.reportActivity(avatar, null);
      this.returnHome(avatar);
    }
  }

  private beginPoiRoute(avatar: AvatarNode) {
    const poi = poiById(avatar.agent.officePoiId ?? "");
    const slot = poi?.slots.find((s) => s.id === avatar.agent.officeSlotId);
    if (!poi || !slot) return;

    const target = this.toCentered(slot.position.x, slot.position.z);
    const pathPts = findPath(
      { x: avatar.root.position.x + this.centerOffset.x, z: avatar.root.position.z + this.centerOffset.z },
      { x: slot.position.x, z: slot.position.z },
    ).map((p) => ({ x: p.x - this.centerOffset.x, z: p.z - this.centerOffset.z }));

    avatar.activePath = {
      id: `poi-${poi.id}-${slot.id}`,
      loop: false,
      waypoints: pathPts.length ? pathPts : [{ x: target.x, z: target.z }],
    };
    avatar.pathIndex = 0;
    avatar.idleBehavior = "poi";
    avatar.routeBusy = true;
    avatar.behaviorEnd = 0;
  }

  private animatePoi(avatar: AvatarNode, t: number, dt: number) {
    const poi = poiById(avatar.agent.officePoiId ?? "");
    const slot = poi?.slots.find((s) => s.id === avatar.agent.officeSlotId);
    if (!poi || !slot) {
      avatar.idleBehavior = "patrol";
      avatar.routeBusy = false;
      return;
    }

    const wp = avatar.activePath.waypoints[avatar.pathIndex];
    if (wp && avatar.routeBusy) {
      const target = new Vector3(wp.x, avatar.root.position.y, wp.z);
      const arrived = this.walkToward(avatar, target, 1.4, dt);
      this.reportActivity(avatar, "walking");
      if (arrived) {
        avatar.pathIndex += 1;
        if (avatar.pathIndex >= avatar.activePath.waypoints.length) {
          avatar.routeBusy = false;
          const dest = this.toCentered(slot.position.x, slot.position.z);
          avatar.root.position.x = dest.x;
          avatar.root.position.z = dest.z;
          avatar.facing = slot.facing;
          avatar.root.rotation.y = slot.facing;
          this.plantFeet(avatar);
          playAgentAnimation(avatar, "idle");
          this.reportActivity(avatar, slot.animation);
        }
      }
      return;
    }

    // Active at POI — procedural pose until status clears.
    playAgentAnimation(avatar, "idle");
    this.reportActivity(avatar, slot.animation);
    if (slot.animation === "sitting_sofa") {
      avatar.root.position.y = avatar.footOffset + floorYAt(0, 0) - 0.18;
      avatar.root.rotation.y = slot.facing;
    } else if (slot.animation === "playing_foosball") {
      avatar.root.rotation.y = slot.facing + Math.sin(t * 3 + avatar.phase) * 0.15;
      this.plantFeet(avatar);
    } else if (slot.animation === "preparing_coffee") {
      avatar.root.rotation.y = slot.facing;
      avatar.root.position.y = avatar.footOffset + Math.sin((t + avatar.phase) * 2) * 0.01;
    } else {
      this.plantFeet(avatar);
    }
    avatar.facing = avatar.root.rotation.y;
  }

  private returnHome(avatar: AvatarNode) {
    const pathPts = findPath(
      { x: avatar.root.position.x + this.centerOffset.x, z: avatar.root.position.z + this.centerOffset.z },
      { x: avatar.homePos.x + this.centerOffset.x, z: avatar.homePos.z + this.centerOffset.z },
    ).map((p) => ({ x: p.x - this.centerOffset.x, z: p.z - this.centerOffset.z }));
    avatar.activePath = { id: `home-${avatar.agent.id}`, loop: false, waypoints: pathPts };
    avatar.pathIndex = 0;
    avatar.idleBehavior = "patrol";
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
  private static readonly TURN_SPEED = Math.PI * 2.2;
  /** Must be facing within this tolerance before advancing position. */
  private static readonly FACING_TOLERANCE = 0.08;
  private static readonly SEPARATION = AGENT_RADIUS * 2.05;

  private walkToward(avatar: AvatarNode, target: Vector3, speed: number, dt: number): boolean {
    const pos = avatar.root.position;
    let dx = target.x - pos.x;
    let dz = target.z - pos.z;

    // Separation from other agents.
    for (const other of this.avatars.values()) {
      if (other === avatar) continue;
      const ox = pos.x - other.root.position.x;
      const oz = pos.z - other.root.position.z;
      const d2 = ox * ox + oz * oz;
      const minD = OfficeScene.SEPARATION;
      if (d2 > 1e-6 && d2 < minD * minD) {
        const d = Math.sqrt(d2);
        const push = ((minD - d) / d) * 0.55;
        dx += ox * push;
        dz += oz * push;
      }
    }

    const dist = Math.sqrt(dx * dx + dz * dz);
    if (dist < 0.22) {
      pos.x = target.x;
      pos.z = target.z;
      this.plantFeet(avatar);
      playAgentAnimation(avatar, "idle");
      return true;
    }

    const heading = Math.atan2(dx, dz);
    const turned = this.turnToward(avatar, heading, dt);
    if (!turned) {
      playAgentAnimation(avatar, "idle");
      this.plantFeet(avatar);
      return false;
    }

    playAgentAnimation(avatar, "walking");
    const step = Math.min(speed * dt, dist);
    pos.x += (dx / dist) * step;
    pos.z += (dz / dist) * step;
    this.plantFeet(avatar);
    return false;
  }

  /** Plant feet exactly on the floor surface using footOffset + nav floor height. */
  private plantFeet(avatar: AvatarNode) {
    const y = floorYAt(avatar.root.position.x, avatar.root.position.z) + avatar.footOffset;
    avatar.root.position.y = y;
    avatar.baseY = y;
  }

  private reportActivity(avatar: AvatarNode, activity: SecondaryActivity) {
    if (avatar.reportedActivity === activity) return;
    // Prefer server-driven labels when present.
    if (avatar.agent.secondaryActivity && activity !== "walking" && activity != null) {
      // still update walking vs active distinctions through callback for local-only agents
    }
    avatar.reportedActivity = activity;
    this.callbacks.onAgentActivity?.(avatar.agent.id, activity);
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

  /** Drop bloom / shadows when FPS stays low to keep the office responsive. */
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
      this.engine.setHardwareScalingLevel(1);
    } else if (next === "medium") {
      this.pipeline.bloomEnabled = true;
      this.pipeline.bloomWeight = OFFICE_BLOOM.weight * 0.65;
      this.engine.setHardwareScalingLevel(1.25);
    } else {
      this.pipeline.bloomEnabled = false;
      this.engine.setHardwareScalingLevel(1.6);
    }
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
function isIdleVisual(state: string): boolean {
  return state === "idle" || state === "walking";
}
