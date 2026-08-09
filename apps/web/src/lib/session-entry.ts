/**
 * Signed-in visitors who hit the marketing home are sent straight to the app.
 *
 * `?landing` opts back out so the marketing page stays reachable without
 * logging out (useful when reviewing the public site as a signed-in admin).
 *
 * The same rule is duplicated as a pre-boot inline script in index.html so the
 * prerendered landing snapshot never flashes before the SPA bundle loads. Keep
 * both in sync.
 */
export const LANDING_OPT_OUT_PARAM = "landing";

export function shouldSkipLanding(searchStr: string, hasSession: boolean): boolean {
  if (!hasSession) return false;
  return !new URLSearchParams(searchStr).has(LANDING_OPT_OUT_PARAM);
}
