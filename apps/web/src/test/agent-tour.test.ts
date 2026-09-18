import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("marketing agent tour", () => {
  it("lazy-loads 3D agent previews even when the web app is account-only", () => {
    const src = readFileSync("src/components/landing/agent-tour.tsx", "utf8");
    expect(src).toContain('import("@/three/agent-preview")');
    expect(src).not.toContain("DESKTOP_ONLY_WEB");
    expect(src).not.toContain("StaticAgentPreview");
  });
});
