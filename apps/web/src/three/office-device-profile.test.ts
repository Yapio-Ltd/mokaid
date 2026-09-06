import { describe, expect, it } from "vitest";
import {
  detectOfficeDeviceProfile,
  isAngleDirect3D,
  refineProfileForRenderer,
  safeOfficeProfile,
} from "./office-device-profile";

const ANGLE_D3D11 =
  "ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Direct3D11 vs_5_0 ps_5_0, D3D11-31.0.15.5123)";
const ANGLE_D3D11_SHORT =
  "ANGLE (Intel, Intel(R) UHD Graphics 630 (0x00003E92) D3D11 vs_5_0 ps_5_0, D3D11)";
const ANGLE_METAL = "ANGLE (Apple, ANGLE Metal Renderer: Apple M2, Unspecified Version)";
const APPLE_GPU = "Apple M2";
const SWIFTSHADER = "Google SwiftShader";

describe("isAngleDirect3D", () => {
  it("matches Chrome Windows ANGLE/D3D", () => {
    expect(isAngleDirect3D(ANGLE_D3D11)).toBe(true);
    expect(isAngleDirect3D(ANGLE_D3D11_SHORT)).toBe(true);
  });

  it("rejects Metal, Apple GPU and SwiftShader", () => {
    expect(isAngleDirect3D(ANGLE_METAL)).toBe(false);
    expect(isAngleDirect3D(APPLE_GPU)).toBe(false);
    expect(isAngleDirect3D(SWIFTSHADER)).toBe(false);
  });
});

describe("refineProfileForRenderer", () => {
  const desktop = detectOfficeDeviceProfile();

  it("caps lights and uses Poisson shadows on ANGLE/D3D11", () => {
    const refined = refineProfileForRenderer(desktop, ANGLE_D3D11);
    expect(refined.variant).toBe("angle");
    expect(refined.initialQuality).toBe("low");
    expect(refined.shadowsEnabled).toBe(false);
    expect(refined.maxSimultaneousLights).toBe(4);
    expect(refined.minAreaLightEnergy).toBeGreaterThanOrEqual(45);
    expect(refined.shadowSampling).toBe("poisson");
    expect(refined.tiers.low.bloomEnabled).toBe(false);
    expect(refined.tiers.low.samples).toBe(1);
    expect(refined.tiers.high.samples).toBe(1);
  });

  it("leaves Metal / Apple GPU / SwiftShader unchanged", () => {
    for (const renderer of [ANGLE_METAL, APPLE_GPU, SWIFTSHADER]) {
      const refined = refineProfileForRenderer(desktop, renderer);
      expect(refined.variant).toBe(desktop.variant);
      expect(refined.maxSimultaneousLights).toBe(desktop.maxSimultaneousLights);
      expect(refined.shadowSampling).toBe(desktop.shadowSampling);
    }
  });

  it("does not re-refine a safe profile", () => {
    const safe = safeOfficeProfile(desktop);
    expect(refineProfileForRenderer(safe, ANGLE_D3D11).variant).toBe("safe");
  });
});

describe("safeOfficeProfile", () => {
  it("disables shadows and bounds lights", () => {
    const safe = safeOfficeProfile(detectOfficeDeviceProfile());
    expect(safe.variant).toBe("safe");
    expect(safe.shadowsEnabled).toBe(false);
    expect(safe.maxSimultaneousLights).toBe(8);
    expect(safe.tiers.high.samples).toBe(1);
  });
});
