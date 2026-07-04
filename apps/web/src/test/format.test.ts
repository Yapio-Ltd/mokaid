import { describe, expect, it } from "vitest";
import { formatBytes, formatCents, initials } from "@/lib/format";

describe("formatBytes", () => {
  it("formats byte sizes", () => {
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(2048)).toBe("2.0 KB");
    expect(formatBytes(2_400_000)).toBe("2.3 MB");
    expect(formatBytes(null)).toBe("—");
  });
});

describe("formatCents", () => {
  it("formats currency from cents", () => {
    expect(formatCents(11900)).toBe("$119.00");
    expect(formatCents(0)).toBe("$0.00");
  });
});

describe("initials", () => {
  it("extracts initials from names", () => {
    expect(initials("Tom Jami")).toBe("TJ");
    expect(initials("Ava")).toBe("A");
    expect(initials(null)).toBe("?");
  });
});
