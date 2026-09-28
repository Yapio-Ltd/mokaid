import { afterEach, describe, expect, it } from "vitest";
import { resolveDesktopTier } from "@/lib/cinematic-network-tier";

describe("resolveDesktopTier", () => {
  it("stays on base for saveData and slow links", () => {
    expect(resolveDesktopTier({ connection: { saveData: true, effectiveType: "4g", downlink: 50 } })).toBe(
      "base",
    );
    expect(resolveDesktopTier({ connection: { effectiveType: "2g", downlink: 0.5 } })).toBe("base");
    expect(resolveDesktopTier({ connection: { effectiveType: "4g", downlink: 1 } })).toBe("base");
    expect(resolveDesktopTier({ connection: { effectiveType: "3g", downlink: 2 } })).toBe("base");
  });

  it("selects high on strong 4g / fibre signals", () => {
    expect(resolveDesktopTier({ connection: { effectiveType: "4g", downlink: 10, rtt: 40 } })).toBe(
      "high",
    );
    expect(resolveDesktopTier({ connection: { downlink: 20 } })).toBe("high");
  });

  it("defaults to high when NetInfo is missing unless explicitly blocked", () => {
    expect(resolveDesktopTier({ connection: null, online: true })).toBe("high");
    expect(
      resolveDesktopTier({ connection: null, online: true, allowMissingApiUpgrade: false }),
    ).toBe("base");
    expect(resolveDesktopTier({ connection: null, online: false })).toBe("base");
  });
});
