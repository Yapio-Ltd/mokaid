/** Only this CSRF marker is visible to JS. Authentication lives in an HttpOnly cookie. */
const COOKIE_SESSION_PREFIX = "browser:";

export function browserCsrfToken(token: string | null): string | null {
  return token?.startsWith(COOKIE_SESSION_PREFIX)
    ? token.slice(COOKIE_SESSION_PREFIX.length)
    : null;
}

export function sessionHeaders(token: string | null): Record<string, string> {
  const csrf = browserCsrfToken(token);
  if (csrf) return { "x-csrf-token": csrf };
  return token ? { Authorization: `Bearer ${token}` } : {};
}
