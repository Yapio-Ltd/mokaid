import { describe, expect, it } from "vitest";
import {
  MAX_RECOVERY_ATTEMPTS,
  RECOVERY_WINDOW_MS,
  nextRecoveryStep,
  resetRecoveryState,
  shouldRebuildOnAttach,
} from "./office-recovery";

describe("nextRecoveryStep", () => {
  const t0 = 1_000_000;

  it("first failure retries with the same profile", () => {
    expect(nextRecoveryStep(0, null, t0)).toEqual({
      kind: "retry",
      attempt: 1,
      useSafeProfile: false,
    });
  });

  it("second failure retries with the safe profile", () => {
    expect(nextRecoveryStep(1, t0, t0 + 1_000)).toEqual({
      kind: "retry",
      attempt: 2,
      useSafeProfile: true,
    });
  });

  it("third failure still retries (last attempt, safe)", () => {
    expect(nextRecoveryStep(2, t0, t0 + 2_000)).toEqual({
      kind: "retry",
      attempt: 3,
      useSafeProfile: true,
    });
  });

  it("fails after 3 attempts inside the 5-minute window", () => {
    expect(nextRecoveryStep(MAX_RECOVERY_ATTEMPTS, t0, t0 + 60_000)).toEqual({
      kind: "failed",
    });
  });

  it("resets the window after 5 minutes and retries with the same profile", () => {
    expect(nextRecoveryStep(3, t0, t0 + RECOVERY_WINDOW_MS + 1)).toEqual({
      kind: "retry",
      attempt: 1,
      useSafeProfile: false,
    });
  });

  it("resetRecoveryState clears attempts", () => {
    expect(resetRecoveryState()).toEqual({ attempts: 0, firstFailureAt: null });
  });
});

describe("shouldRebuildOnAttach", () => {
  it("does not rebuild when reparenting a live canvas", () => {
    expect(shouldRebuildOnAttach({ canvasHasParent: true, contextLost: false })).toBe(false);
  });

  it("does not rebuild a parented canvas even if isContextLost is stale", () => {
    expect(shouldRebuildOnAttach({ canvasHasParent: true, contextLost: true })).toBe(false);
  });

  it("rebuilds only an orphaned lost context", () => {
    expect(shouldRebuildOnAttach({ canvasHasParent: false, contextLost: true })).toBe(true);
    expect(shouldRebuildOnAttach({ canvasHasParent: false, contextLost: false })).toBe(false);
  });
});
