/**
 * OfficeScene: isolated Babylon.js layer.
 *
 * The 3D world is fully decoupled from React: it is created once, receives
 * agent updates through `updateAgents`, and reports interactions through
 * callbacks. All office furniture and avatars are procedural placeholders
 * (see asset-manifest.ts) until production GLB assets are delivered.
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
import { statusColors } from "@mokaid/design-tokens";
import type { SceneAgent, SceneCallbacks } from "./types";

const SEATS_PER_ROW = 5;
const DESK_SPACING_X = 4.2;

interface AvatarNode {
  root: TransformNode;
  body: Mesh;
  head: Mesh;
  ring: Mesh;
  agent: SceneAgent;
  phase: number;
  baseY: number;
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

    this.engine.runRenderLoop(() => {
      if (this.disposed) return;
      this.animate();
      this.scene.render();
      this.reportOverlay();
    });

    const resize = () => this.engine.resize();
    window.addEventListener("resize", resize);
    this.scene.onDisposeObservable.add(() => window.removeEventListener("resize", resize));
  }

  /* ---------- setup ---------- */

  private setupCamera() {
    const camera = new ArcRotateCamera(
      "camera",
      -Math.PI / 3.2,
      Math.PI / 3.4,
      26,
      new Vector3(0, 0, -1),
      this.scene,
    );
    camera.attachControl(this.canvas, true);
    camera.lowerRadiusLimit = 12;
    camera.upperRadiusLimit = 42;
    camera.lowerBetaLimit = Math.PI / 6;
    camera.upperBetaLimit = Math.PI / 2.4;
    camera.wheelDeltaPercentage = 0.01;
    camera.panningSensibility = 0;
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

    // Desk grid: 2 rows of 5
    let slot = 0;
    for (let row = 0; row < 2; row++) {
      for (let col = 0; col < SEATS_PER_ROW; col++) {
        const x = (col - (SEATS_PER_ROW - 1) / 2) * DESK_SPACING_X;
        const z = row === 0 ? -4.5 : 1.5;
        this.buildDesk(x, z, slot);
        this.deskSlots.push(new Vector3(x, 0, z + 1.15));
        slot += 1;
      }
    }

    // Plants in corners
    for (const [x, z] of [
      [-11.5, -9.5],
      [11.5, -9.5],
      [-11.5, 8.5],
      [11.5, 8.5],
    ] as const) {
      this.buildPlant(x, z);
    }

    // Meeting table
    const table = MeshBuilder.CreateCylinder("meeting-table", { diameter: 3.4, height: 0.14 }, this.scene);
    table.position.set(0, 0.95, 7);
    table.material = this.material("tabletop", "#2a2a38");
    const tableLeg = MeshBuilder.CreateCylinder("meeting-leg", { diameter: 0.35, height: 0.95 }, this.scene);
    tableLeg.position.set(0, 0.47, 7);
    tableLeg.material = this.material("leg", "#3a3a4c");
  }

  private buildDesk(x: number, z: number, index: number) {
    const group = new TransformNode(`desk-${index}`, this.scene);
    group.position.set(x, 0, z);

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

    const seen = new Set<string>();

    agents.forEach((agent, index) => {
      seen.add(agent.id);
      const existing = this.avatars.get(agent.id);
      if (existing) {
        existing.agent = agent;
        this.applyStatusVisual(existing);
      } else {
        this.createAvatar(agent, agent.seatIndex >= 0 ? agent.seatIndex : index);
      }
    });

    // Remove avatars for agents that no longer exist
    for (const [id, avatar] of this.avatars) {
      if (!seen.has(id)) {
        avatar.root.dispose();
        this.avatars.delete(id);
      }
    }
  }

  private createAvatar(agent: SceneAgent, seatIndex: number) {
    const slot = this.deskSlots[seatIndex % this.deskSlots.length] ?? Vector3.Zero();

    const root = new TransformNode(`avatar-${agent.id}`, this.scene);
    root.position.copyFrom(slot);

    const body = MeshBuilder.CreateCapsule(`avatar-body-${agent.id}`, { radius: 0.32, height: 1.15, subdivisions: 4 }, this.scene);
    body.position.y = 1.05;
    body.parent = root;
    body.material = this.material(`body-${agent.id}`, agent.color);
    body.isPickable = true;
    body.metadata = { agentId: agent.id };
    this.shadowGenerator?.addShadowCaster(body);

    const head = MeshBuilder.CreateSphere(`avatar-head-${agent.id}`, { diameter: 0.5, segments: 12 }, this.scene);
    head.position.y = 1.9;
    head.parent = root;
    head.material = this.material(`head-${agent.id}`, agent.color, 0.12);
    head.isPickable = true;
    head.metadata = { agentId: agent.id };

    const ring = MeshBuilder.CreateTorus(`avatar-ring-${agent.id}`, { diameter: 1.05, thickness: 0.06, tessellation: 24 }, this.scene);
    ring.position.y = 0.06;
    ring.parent = root;
    ring.isPickable = false;

    const avatar: AvatarNode = {
      root,
      body,
      head,
      ring,
      agent,
      phase: Math.random() * Math.PI * 2,
      baseY: 0,
    };

    this.avatars.set(agent.id, avatar);
    this.applyStatusVisual(avatar);
  }

  private applyStatusVisual(avatar: AvatarNode) {
    const statusColor =
      (statusColors as Record<string, string>)[avatar.agent.status] ?? statusColors.offline;

    avatar.ring.material = this.material(`ring-${avatar.agent.status}`, statusColor, 0.6);

    const isOffline = ["offline", "archived"].includes(avatar.agent.status);
    const bodyMat = avatar.body.material as StandardMaterial;
    bodyMat.alpha = isOffline ? 0.35 : 1;
    const headMat = avatar.head.material as StandardMaterial;
    headMat.alpha = isOffline ? 0.35 : 1;
  }

  /* ---------- animation state machine ---------- */

  private animate() {
    const t = performance.now() / 1000;

    for (const avatar of this.avatars.values()) {
      const { root, agent, phase } = avatar;
      const state = agent.visualState;

      switch (state) {
        case "typing":
          root.position.y = avatar.baseY + Math.abs(Math.sin((t + phase) * 9)) * 0.045;
          root.rotation.y = Math.sin((t + phase) * 2) * 0.05;
          break;
        case "working":
        case "reviewing":
        case "learning":
          root.position.y = avatar.baseY + Math.sin((t + phase) * 2.4) * 0.03;
          root.rotation.y = Math.sin((t + phase) * 0.8) * 0.12;
          break;
        case "thinking":
          root.rotation.y = Math.sin((t + phase) * 0.6) * 0.3;
          root.position.y = avatar.baseY;
          break;
        case "waiting":
        case "requesting_approval":
          root.position.y = avatar.baseY + Math.abs(Math.sin((t + phase) * 3.2)) * 0.12;
          break;
        case "blocked":
          root.rotation.y = Math.sin((t + phase) * 14) * 0.04;
          root.position.y = avatar.baseY;
          break;
        case "celebrating":
          root.position.y = avatar.baseY + Math.abs(Math.sin((t + phase) * 5)) * 0.35;
          root.rotation.y += 0.04;
          break;
        case "talking":
          root.position.y = avatar.baseY + Math.sin((t + phase) * 4) * 0.02;
          root.rotation.y = Math.sin((t + phase) * 1.5) * 0.2;
          break;
        case "away":
        case "offline":
          root.position.y = avatar.baseY;
          root.rotation.y = 0;
          break;
        default: // idle
          root.position.y = avatar.baseY + Math.sin((t + phase) * 1.4) * 0.02;
          break;
      }
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

  private reportOverlay() {
    const now = performance.now();
    if (now - this.fpsTimer > 500) {
      this.fpsTimer = now;
      this.callbacks.onFps(Math.round(this.engine.getFps()));
    }

    const positions = new Map<string, { x: number; y: number; visible: boolean }>();
    const camera = this.scene.activeCamera;
    if (!camera) return;

    for (const [id, avatar] of this.avatars) {
      const worldPos = avatar.head.getAbsolutePosition().add(new Vector3(0, 0.65, 0));
      const projected = Vector3.Project(
        worldPos,
        Matrix.Identity(),
        this.scene.getTransformMatrix(),
        camera.viewport.toGlobal(this.engine.getRenderWidth(), this.engine.getRenderHeight()),
      );

      positions.set(id, {
        x: projected.x,
        y: projected.y,
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
    this.engine.stopRenderLoop();
    this.scene.dispose();
    this.engine.dispose();
  }
}
