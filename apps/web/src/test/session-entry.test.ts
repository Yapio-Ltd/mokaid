import { describe, expect, it } from "vitest";
import { shouldSkipLanding } from "@/lib/session-entry";

describe("shouldSkipLanding", () => {
  it("keeps signed-out visitors on the marketing home", () => {
    expect(shouldSkipLanding("", false)).toBe(false);
    expect(shouldSkipLanding("?ref=twitter", false)).toBe(false);
  });

  it("sends signed-in visitors to the app", () => {
    expect(shouldSkipLanding("", true)).toBe(true);
    expect(shouldSkipLanding("?ref=twitter", true)).toBe(true);
  });

  it("honours the ?landing opt-out", () => {
    expect(shouldSkipLanding("?landing", true)).toBe(false);
    expect(shouldSkipLanding("?landing=1", true)).toBe(false);
    expect(shouldSkipLanding("?ref=twitter&landing", true)).toBe(false);
  });
});
