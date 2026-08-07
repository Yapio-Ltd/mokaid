/**
 * Device-tiered render profiles for the office scene.
 *
 * Desktop (macOS / Windows / Linux) keeps the full visual target: high tier,
 * MSAA 4×, full bloom, Retina resolution. Touch devices (iPad / iPhone /
 * Android tablets) get a profile sized for mobile GPU + thermal budgets and
 * START on the lowest tier, then get promoted by the FPS-driven quality
 * adapter once the device proves it can sustain more.
 *
 * "Start low, climb up" is deliberate: the previous "start high, degrade
 * later" policy left ~12 s of full-Retina MSAA rendering before the first
 * downgrade — enough for an iPad to hit its GPU memory ceiling or thermal
 * shutdown during the heaviest phase (46 MB GLB import + shader compilation).
 */

export type RenderQuality = "high" | "medium" | "low";

export interface QualityTierSettings {
  bloomEnabled: boolean;
  /** Multiplier applied to OFFICE_BLOOM.weight. */
  bloomWeightMul: number;
  /** MSAA sample count on the pipeline render target (1 = off). */
  samples: number;
  fxaa: boolean;
  /**
   * Multiplier over the engine's base hardware scaling level (1/dpr).
   * The result is clamped to ≤ 1, i.e. the scene never renders below the
   * canvas CSS resolution.
   */
  scaleMul: number;
}

export interface OfficeDeviceProfile {
  kind: "desktop" | "mobile";
  /** Cap passed to Engine adaptToDeviceRatio (render buffer dpr ceiling). */
  limitDeviceRatio: number;
  /**
   * Render-loop frame cap. Uncapped rAF renders at 120 Hz on ProMotion
   * displays — double the GPU work for an ambient scene, and the main
   * thermal driver on tablets.
   */
  maxFps: number;
  /**
   * "high-performance" pins dual-GPU laptops to the discrete GPU;
   * on tablets it only invites thermal throttling.
   */
  powerPreference: "high-performance" | "default";
  initialQuality: RenderQuality;
  /** Anisotropic filtering level applied to scene textures. */
  anisotropy: number;
  /** Per-material simultaneous-light cap for the environment PBR shaders. */
  maxSimultaneousLights: number;
  /** Whether the lantern shadow map is created at all. */
  shadowsEnabled: boolean;
  /**
   * Blender AREA lights below this wattage are skipped (0 keeps all).
   * Used on mobile to shed the weakest fill panels — the cheapest lighting
   * reduction that keeps the key/accent lights intact.
   */
  minAreaLightEnergy: number;
  tiers: Record<RenderQuality, QualityTierSettings>;
}

const DESKTOP_PROFILE: OfficeDeviceProfile = {
  kind: "desktop",
  limitDeviceRatio: 2,
  maxFps: 60,
  powerPreference: "high-performance",
  initialQuality: "high",
  // 16× was applied before; ≥8× is indistinguishable at this fixed
  // isometric angle and halves the sampling cost.
  anisotropy: 8,
  maxSimultaneousLights: 36,
  shadowsEnabled: true,
  minAreaLightEnergy: 0,
  tiers: {
    high: { bloomEnabled: true, bloomWeightMul: 1, samples: 4, fxaa: false, scaleMul: 1 },
    medium: { bloomEnabled: true, bloomWeightMul: 0.75, samples: 2, fxaa: false, scaleMul: 1.15 },
    low: { bloomEnabled: true, bloomWeightMul: 0.45, samples: 2, fxaa: true, scaleMul: 1.35 },
  },
};

const MOBILE_PROFILE: OfficeDeviceProfile = {
  kind: "mobile",
  limitDeviceRatio: 1.5,
  maxFps: 30,
  powerPreference: "default",
  initialQuality: "low",
  anisotropy: 4,
  maxSimultaneousLights: 12,
  shadowsEnabled: false,
  minAreaLightEnergy: 45,
  tiers: {
    high: { bloomEnabled: true, bloomWeightMul: 0.75, samples: 2, fxaa: false, scaleMul: 1.15 },
    medium: { bloomEnabled: true, bloomWeightMul: 0.5, samples: 1, fxaa: true, scaleMul: 1.35 },
    // scaleMul 1.5 lands exactly on scaling level 1 = CSS resolution.
    low: { bloomEnabled: false, bloomWeightMul: 0, samples: 1, fxaa: true, scaleMul: 1.5 },
  },
};

/**
 * Classify the current device. Heuristics, most reliable first:
 * - Multi-touch + coarse pointer → tablet/phone (iPadOS 13+ masquerades as
 *   macOS in the UA but still reports maxTouchPoints > 1).
 * - Mobile UA tokens as a fallback for devices with mice attached.
 * - deviceMemory ≤ 4 GB (Chromium only) → budget hardware, treat as mobile.
 */
export function detectOfficeDeviceProfile(): OfficeDeviceProfile {
  if (typeof window === "undefined" || typeof navigator === "undefined") {
    return DESKTOP_PROFILE;
  }

  const coarsePointer = window.matchMedia?.("(pointer: coarse)")?.matches ?? false;
  const multiTouch = (navigator.maxTouchPoints ?? 0) > 1;
  const mobileUa = /android|iphone|ipad|ipod|mobile/i.test(navigator.userAgent);
  const lowMemory =
    ((navigator as { deviceMemory?: number }).deviceMemory ?? Infinity) <= 4;

  if ((multiTouch && coarsePointer) || mobileUa || lowMemory) {
    return MOBILE_PROFILE;
  }
  return DESKTOP_PROFILE;
}
