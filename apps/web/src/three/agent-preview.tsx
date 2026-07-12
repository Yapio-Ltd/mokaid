/**
 * AgentPreview3D / AgentHeadPreview3D — Babylon character previews.
 *
 * Lighting is tuned for textured PBR characters (original skin / clothing colors).
 * Accent tint is never applied when the GLB already has authoring textures.
 */

import { useEffect, useRef, useState } from "react";
import {
  ArcRotateCamera,
  Color3,
  Color4,
  DirectionalLight,
  Engine,
  HemisphericLight,
  PBRMaterial,
  PointerEventTypes,
  Scene,
  SceneLoader,
  Vector3,
} from "@babylonjs/core";
import "@babylonjs/loaders/glTF";
import type { AbstractMesh } from "@babylonjs/core";
import { Avatar } from "@/components/ui/avatar";

import { AGENT_GLB_URL, applyTint, resolveAgentGlbUrl } from "./agent-model";

const TARGET_HEIGHT = 1.75;

/** Soft studio lighting so textured faces stay readable on dark UI. */
function setupPortraitLighting(scene: Scene) {
  scene.imageProcessingConfiguration.exposure = 1.55;
  scene.imageProcessingConfiguration.contrast = 1.12;
  scene.imageProcessingConfiguration.toneMappingEnabled = true;

  const hemi = new HemisphericLight("hemi", new Vector3(0.25, 1, 0.35), scene);
  hemi.intensity = 2.1;
  hemi.diffuse = Color3.White();
  hemi.groundColor = new Color3(0.55, 0.55, 0.6);
  hemi.specular = new Color3(0.35, 0.35, 0.35);

  const key = new DirectionalLight("key", new Vector3(-0.35, -0.9, -0.55), scene);
  key.intensity = 1.55;
  key.diffuse = new Color3(1, 0.98, 0.95);

  const fill = new DirectionalLight("fill", new Vector3(0.7, -0.25, 0.35), scene);
  fill.intensity = 0.85;
  fill.diffuse = new Color3(0.88, 0.92, 1);

  const rim = new DirectionalLight("rim", new Vector3(0.15, -0.2, 0.9), scene);
  rim.intensity = 0.55;
  rim.diffuse = new Color3(0.95, 0.95, 1);
}

/** Boost direct lighting response on PBR materials (no IBL HDR available). */
function boostMaterialLighting(meshes: AbstractMesh[]) {
  for (const mesh of meshes) {
    const mat = mesh.material;
    if (mat instanceof PBRMaterial) {
      mat.directIntensity = 1.6;
      mat.environmentIntensity = 0.35;
      mat.specularIntensity = Math.min(mat.specularIntensity ?? 1, 0.85);
    }
  }
}

function normalizeStandingRoot(root: AbstractMesh) {
  root.scaling.setAll(1);
  root.computeWorldMatrix(true);
  let bounds = root.getHierarchyBoundingVectors(true);
  let modelHeight = bounds.max.y - bounds.min.y;
  if (modelHeight > 0) {
    root.scaling.setAll(TARGET_HEIGHT / modelHeight);
    root.computeWorldMatrix(true);
    bounds = root.getHierarchyBoundingVectors(true);
    modelHeight = bounds.max.y - bounds.min.y;
  }
  root.position.y = -bounds.min.y;
  return { bounds, modelHeight };
}

interface Props {
  color: string;
  name: string;
  /** Width/height in px. Defaults to 220 × 300. */
  width?: number;
  height?: number;
  /** Catalog CDN path for the character GLB. */
  cdnPath?: string | null;
  /** When false, never tint — keep authoring colors. Default true (tint only if untextured). */
  allowTint?: boolean;
  /** Clip to loop. Defaults to idle. */
  animation?: "idle" | "walking";
}

function pickClip(groups: { name: string; start: (loop?: boolean, speed?: number, from?: number, to?: number, isAdditive?: boolean) => void; stop: () => void; from: number; to: number }[], preferred: string) {
  const lower = preferred.toLowerCase();
  return (
    groups.find((ag) => {
      const n = ag.name.toLowerCase();
      return n === lower || n.endsWith(`-${lower}`) || n.includes(lower);
    }) ?? groups[0]
  );
}

export function AgentPreview3D({
  color,
  name,
  width = 220,
  height = 300,
  cdnPath,
  allowTint = true,
  animation = "idle",
}: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const engineRef = useRef<Engine | null>(null);
  const meshesRef = useRef<AbstractMesh[]>([]);
  const [failed, setFailed] = useState(false);
  const glbUrl = resolveAgentGlbUrl(cdnPath) || AGENT_GLB_URL;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    let disposed = false;
    let engine: Engine;

    async function init() {
      try {
        engine = new Engine(canvas, true, {
          preserveDrawingBuffer: false,
          stencil: false,
          adaptToDeviceRatio: true,
        });
        engineRef.current = engine;

        const scene = new Scene(engine);
        scene.clearColor = new Color4(0, 0, 0, 0);

        const camera = new ArcRotateCamera("cam", -Math.PI / 2, Math.PI / 2.5, 5, Vector3.Zero(), scene);
        const FIXED_BETA = Math.PI / 2.5;
        camera.lowerBetaLimit = FIXED_BETA;
        camera.upperBetaLimit = FIXED_BETA;
        camera.lowerRadiusLimit = camera.radius;
        camera.upperRadiusLimit = camera.radius;

        canvasRef.current?.addEventListener("wheel", (e) => e.preventDefault(), { passive: false });
        camera.attachControl(canvas, true);

        setupPortraitLighting(scene);

        const result = await SceneLoader.ImportMeshAsync("", glbUrl, "", scene);
        if (disposed) return;

        meshesRef.current = result.meshes;

        const root = result.meshes.find((m) => !m.parent) ?? result.meshes[0];
        if (root) {
          const { bounds, modelHeight } = normalizeStandingRoot(root);

          const midY = modelHeight / 2;
          camera.target = new Vector3(0, midY, 0);

          const fovY = camera.fov;
          const aspectRatio = width / height;
          const distByHeight = (modelHeight / 2 / Math.tan(fovY / 2)) * 1.12;
          const modelWidth = bounds.max.x - bounds.min.x;
          const distByWidth = (modelWidth / 2 / Math.tan((fovY * aspectRatio) / 2)) * 1.12;
          const distance = Math.max(distByHeight, distByWidth);

          camera.radius = distance;
          camera.lowerRadiusLimit = distance;
          camera.upperRadiusLimit = distance;
          camera.beta = FIXED_BETA;
        }

        result.animationGroups.forEach((ag) => ag.stop());
        const clip = pickClip(result.animationGroups, animation);
        if (clip) clip.start(true);

        boostMaterialLighting(result.meshes);
        if (allowTint) applyTint(result.meshes, color);

        let autoAngle = 0;
        let isDragging = false;

        scene.onPointerObservable.add((info) => {
          if (info.type === PointerEventTypes.POINTERDOWN) isDragging = true;
          if (info.type === PointerEventTypes.POINTERUP) isDragging = false;
        });

        scene.onBeforeRenderObservable.add(() => {
          if (!isDragging) autoAngle += 0.005;
          if (root) root.rotation.y = autoAngle;
        });

        engine.runRenderLoop(() => {
          if (!disposed) scene.render();
        });
      } catch (err) {
        console.warn("[AgentPreview3D] load failed, falling back to 2D", err);
        if (!disposed) setFailed(true);
      }
    }

    init();

    return () => {
      disposed = true;
      engineRef.current?.dispose();
      engineRef.current = null;
      meshesRef.current = [];
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [width, height, glbUrl, allowTint, animation]);

  useEffect(() => {
    if (allowTint && meshesRef.current.length > 0) {
      applyTint(meshesRef.current, color);
    }
  }, [color, allowTint]);

  if (failed) {
    return (
      <div className="flex items-center justify-center" style={{ width, height }}>
        <Avatar name={name} size="xl" isAi color={color} />
      </div>
    );
  }

  return (
    <canvas
      ref={canvasRef}
      width={width * 2}
      height={height * 2}
      style={{ width, height, display: "block" }}
      aria-label={`3D preview of agent ${name}`}
    />
  );
}

interface HeadProps {
  color: string;
  name: string;
  /** Diameter in px. Renders into a square canvas cropped to a circle. */
  size?: number;
  /** Catalog CDN path (/assets3d/...). */
  cdnPath?: string | null;
  /** Avatar size token used for the 2D fallback. */
  fallbackSize?: "xs" | "sm" | "md" | "lg" | "xl";
}

/**
 * AgentHeadPreview3D — circular headshot of the agent's catalog GLB.
 * Keeps original textures; pauses the render loop when off-screen.
 */
export function AgentHeadPreview3D({
  color,
  name,
  size = 80,
  cdnPath,
  fallbackSize = "md",
}: HeadProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const engineRef = useRef<Engine | null>(null);
  const [failed, setFailed] = useState(false);
  const glbUrl = resolveAgentGlbUrl(cdnPath) || AGENT_GLB_URL;

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    let disposed = false;
    let engine: Engine;
    let visible = true;

    const onContextLost = (event: Event) => {
      event.preventDefault();
      console.warn("[AgentHeadPreview3D] WebGL context lost — falling back to 2D");
      if (!disposed) setFailed(true);
    };
    canvas.addEventListener("webglcontextlost", onContextLost, false);

    async function init() {
      try {
        engine = new Engine(canvas, true, {
          preserveDrawingBuffer: false,
          stencil: false,
          adaptToDeviceRatio: true,
          // Limit GPU pressure when many portraits exist (dock + profile + office).
          powerPreference: "low-power",
        });
        engineRef.current = engine;

        const scene = new Scene(engine);
        // Soft warm fill so skin reads against dark UI (still transparent outside circle via CSS).
        scene.clearColor = new Color4(0.14, 0.13, 0.18, 1);

        const camera = new ArcRotateCamera(
          "head-cam",
          -Math.PI / 2,
          Math.PI / 2.35,
          1,
          Vector3.Zero(),
          scene,
        );
        camera.inputs.clear();
        camera.minZ = 0.01;

        setupPortraitLighting(scene);

        const result = await SceneLoader.ImportMeshAsync("", glbUrl, "", scene);
        if (disposed) return;

        const root = result.meshes.find((m) => !m.parent) ?? result.meshes[0];
        if (root) {
          const { modelHeight } = normalizeStandingRoot(root);

          // Eye-level front portrait, pulled back so head + shoulders breathe.
          const eyeY = modelHeight * 0.78;
          camera.target = new Vector3(0, eyeY, 0);
          camera.alpha = -Math.PI / 2;
          camera.beta = Math.PI / 2.4;
          const headSpan = modelHeight * 0.42;
          camera.radius = (headSpan / 2 / Math.tan(camera.fov / 2)) * 1.35;
        }

        result.animationGroups.forEach((ag) => ag.stop());
        const idle =
          result.animationGroups.find((ag) => {
            const n = ag.name.toLowerCase();
            return n === "idle" || n.endsWith("-idle") || n.includes("idle");
          }) ?? result.animationGroups[0];
        if (idle) idle.start(true, 1.0, idle.from, idle.to, false);

        boostMaterialLighting(result.meshes);
        // Never tint headshots — accent color is for UI rings only.
        void color;

        engine.runRenderLoop(() => {
          if (!disposed && visible) scene.render();
        });
      } catch (err) {
        console.warn("[AgentHeadPreview3D] load failed, falling back to 2D", err);
        if (!disposed) setFailed(true);
      }
    }

    init();

    const observer = new IntersectionObserver(
      ([entry]) => {
        visible = entry?.isIntersecting ?? true;
      },
      { threshold: 0.05 },
    );
    observer.observe(canvas);

    return () => {
      disposed = true;
      observer.disconnect();
      canvas.removeEventListener("webglcontextlost", onContextLost);
      engineRef.current?.dispose();
      engineRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [size, glbUrl]);

  if (failed) {
    return <Avatar name={name} size={fallbackSize} isAi color={color} />;
  }

  // WebGL canvases ignore border-radius; clip-path is required for a true circle.
  // Also override global corner-shape:squircle so box chrome stays circular.
  return (
    <span
      className="block [corner-shape:round]"
      style={{
        width: size,
        height: size,
        borderRadius: "50%",
        overflow: "hidden",
        clipPath: "circle(50% at 50% 50%)",
        WebkitClipPath: "circle(50% at 50% 50%)",
      }}
    >
      <canvas
        ref={canvasRef}
        width={size * 2}
        height={size * 2}
        style={{
          width: size,
          height: size,
          display: "block",
          clipPath: "circle(50% at 50% 50%)",
          WebkitClipPath: "circle(50% at 50% 50%)",
        }}
        aria-label={`3D portrait of agent ${name}`}
      />
    </span>
  );
}
