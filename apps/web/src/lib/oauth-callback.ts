import { useAuthStore } from "@/stores/auth-store";
import { accountEntryPath, safeAuthReturn } from "@/lib/desktop-rollout";

const RETURN_KEY = "oauth_return_to";
const STEP_KEY = "onboarding_restore_step";

export function setOauthReturn(path: string, onboardingStep?: number) {
  sessionStorage.setItem(RETURN_KEY, path);
  if (onboardingStep != null) {
    sessionStorage.setItem(STEP_KEY, String(onboardingStep));
  }
}

export function consumeOauthReturn(fallback = accountEntryPath()): string {
  const path = sessionStorage.getItem(RETURN_KEY) ?? fallback;
  sessionStorage.removeItem(RETURN_KEY);
  return safeAuthReturn(path);
}

export function consumeOnboardingRestoreStep(): number | null {
  const raw = sessionStorage.getItem(STEP_KEY);
  sessionStorage.removeItem(STEP_KEY);
  if (!raw) return null;
  const step = Number(raw);
  return Number.isFinite(step) ? step : null;
}

export function waitForAuthHydration(): Promise<void> {
  return new Promise((resolve) => {
    if (useAuthStore.persist.hasHydrated()) {
      resolve();
      return;
    }
    const unsub = useAuthStore.persist.onFinishHydration(() => {
      unsub();
      resolve();
    });
  });
}

export function oauthDedupeKey(provider: string, code: string) {
  return `${provider}_oauth:${code}`;
}

const oauthInflight = new Map<string, Promise<unknown>>();

export function runOauthOnce<T>(key: string, run: () => Promise<T>): Promise<T> {
  const existing = oauthInflight.get(key) as Promise<T> | undefined;
  if (existing) return existing;

  const promise = run().finally(() => {
    oauthInflight.delete(key);
  });
  oauthInflight.set(key, promise);
  return promise;
}

export const OAUTH_SUCCESS_MESSAGE = "mokaid:oauth:success" as const;

export type OauthSuccessPayload = {
  type: typeof OAUTH_SUCCESS_MESSAGE;
  provider: string;
  account?: string;
};

/** Open synchronously on click so popup blockers don't reject the OAuth tab. */
export function openOauthPopup(): Window | null {
  return window.open("about:blank", "mokaid_oauth");
}

export function navigateOauthPopup(
  popup: Window | null,
  url: string,
  restore?: { step?: number },
): void {
  if (popup && !popup.closed) {
    popup.location.href = url;
    return;
  }
  if (restore?.step != null) {
    setOauthReturn("/dashboard", restore.step);
  }
  window.location.href = url;
}

export function notifyOauthOpener(provider: string, account?: string): boolean {
  const opener = window.opener as Window | null;
  if (!opener || opener.closed) return false;

  opener.postMessage(
    { type: OAUTH_SUCCESS_MESSAGE, provider, account } satisfies OauthSuccessPayload,
    window.location.origin,
  );
  return true;
}

export function completeOauthInPopup(
  provider: string,
  account: string | undefined,
  navigate: (to: string) => void,
  setMessage: (msg: string) => void,
): void {
  if (notifyOauthOpener(provider, account)) {
    setMessage(
      account
        ? `Connected as ${account}. You can close this tab.`
        : "Connected. You can close this tab.",
    );
    window.setTimeout(() => window.close(), 1200);
    return;
  }

  const returnTo = consumeOauthReturn();
  window.setTimeout(() => navigate(returnTo), 900);
}
