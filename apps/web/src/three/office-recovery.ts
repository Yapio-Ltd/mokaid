/**
 * Pure recovery policy for the office WebGL host.
 *
 * Attempt 1: rebuild with the same device profile (tab eviction / GPU reset).
 * Attempt 2: rebuild with the safe profile (shader compile / TDR).
 * 3 failures inside a 5-minute window → give up until the user retries.
 */

export const RECOVERY_WINDOW_MS = 5 * 60 * 1000;
export const MAX_RECOVERY_ATTEMPTS = 3;

export type RecoveryAction =
  | { kind: "retry"; attempt: number; useSafeProfile: boolean }
  | { kind: "failed" };

export function nextRecoveryStep(
  attempts: number,
  firstFailureAt: number | null,
  now: number,
): RecoveryAction {
  const windowExpired =
    firstFailureAt != null && now - firstFailureAt > RECOVERY_WINDOW_MS;
  const effectiveAttempts = windowExpired ? 0 : Math.max(0, attempts);
  const nextAttempt = effectiveAttempts + 1;

  if (nextAttempt > MAX_RECOVERY_ATTEMPTS) {
    return { kind: "failed" };
  }

  return {
    kind: "retry",
    attempt: nextAttempt,
    useSafeProfile: nextAttempt >= 2,
  };
}

export function resetRecoveryState(): { attempts: number; firstFailureAt: null } {
  return { attempts: 0, firstFailureAt: null };
}

/**
 * The canvas never reparents. Only an orphaned canvas with a lost context
 * (or an explicit webglcontextlost) may reconstruct the scene.
 */
export function shouldRebuildOnAttach(opts: {
  canvasHasParent: boolean;
  contextLost: boolean;
}): boolean {
  if (!opts.contextLost) return false;
  if (opts.canvasHasParent) return false;
  return true;
}
