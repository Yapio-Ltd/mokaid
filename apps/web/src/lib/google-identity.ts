const PENDING_KEY = "mokaid-google-identity";
const RETURN_KEY = "google_auth_return";
const MAX_AGE_MS = 10 * 60 * 1000;

interface PendingGoogleIdentity {
  verifier: string;
  state: string;
  createdAt: number;
}

function base64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

export async function createGooglePkce(): Promise<{ verifier: string; challenge: string }> {
  const verifier = base64Url(crypto.getRandomValues(new Uint8Array(32)));
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return { verifier, challenge: base64Url(new Uint8Array(digest)) };
}

export function rememberGoogleIdentity(
  authorizeUrl: string,
  verifier: string,
  returnTo: string,
): string {
  const url = new URL(authorizeUrl);
  const state = url.searchParams.get("state");
  if (
    url.origin !== "https://accounts.google.com" ||
    url.pathname !== "/o/oauth2/v2/auth" ||
    url.username ||
    url.password ||
    url.hash ||
    !state
  ) {
    throw new Error("Google returned an invalid sign-in address.");
  }
  sessionStorage.setItem(
    PENDING_KEY,
    JSON.stringify({ verifier, state, createdAt: Date.now() } satisfies PendingGoogleIdentity),
  );
  sessionStorage.setItem(RETURN_KEY, returnTo);
  return url.href;
}

export function googleIdentityVerifier(state: string): string {
  try {
    const pending: PendingGoogleIdentity = JSON.parse(
      sessionStorage.getItem(PENDING_KEY) ?? "null",
    );
    if (
      pending &&
      pending.state === state &&
      /^[A-Za-z0-9_-]{43}$/.test(pending.verifier) &&
      pending.createdAt <= Date.now() &&
      Date.now() - pending.createdAt <= MAX_AGE_MS
    ) {
      return pending.verifier;
    }
  } catch {
    /* Treat corrupt or unavailable tab storage as an unbound callback. */
  }
  throw new Error("This sign-in was not started in this tab or has expired. Please start again.");
}

export function clearGoogleIdentity(): void {
  sessionStorage.removeItem(PENDING_KEY);
}
