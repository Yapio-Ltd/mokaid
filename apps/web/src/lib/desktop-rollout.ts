/** The website is always marketing, downloads and account management.
 * Desktop distribution readiness only gates server policy, never the web UI.
 * A literal also lets Rollup remove all legacy Office imports from the build.
 */
export const DESKTOP_ONLY_WEB = true;

export function accountEntryPath(desktopOnly = DESKTOP_ONLY_WEB): "/account" | "/dashboard" {
  return desktopOnly ? "/account" : "/dashboard";
}

export const ACCOUNT_LINKS = [
  { path: "/account", label: "Overview" },
  { path: "/account/profile", label: "Profile & preferences" },
  { path: "/account/security", label: "Security" },
  { path: "/account/billing", label: "Billing" },
  { path: "/account/plans", label: "Plans" },
  { path: "/account/usage", label: "Usage" },
  { path: "/account/spending", label: "Spending & credits" },
  { path: "/account/invoices", label: "Invoices" },
] as const;

/** Keep payment outcome parameters, but never forward arbitrary credentials. */
export function legacyAccountDestination(pathname: string, search = ""): string {
  if (pathname === "/profile" || pathname === "/settings") return "/account/profile";
  if (pathname === "/billing") {
    const params = new URLSearchParams(search);
    const result = new URLSearchParams();
    const checkout = params.get("checkout");
    if (checkout === "success" || checkout === "canceled") result.set("checkout", checkout);
    if (params.get("payment") === "done") result.set("payment", "done");
    return `/account/billing${result.size ? `?${result}` : ""}`;
  }
  return "/download";
}

/** Only local, known destinations survive login. No open redirects or tokens. */
export function safeAuthReturn(candidate: string | null, desktopOnly = DESKTOP_ONLY_WEB): string {
  if (
    !candidate ||
    !candidate.startsWith("/") ||
    candidate.startsWith("//") ||
    candidate.includes("\\") ||
    [...candidate].some((character) => character.charCodeAt(0) <= 32)
  ) {
    return accountEntryPath(desktopOnly);
  }
  const url = new URL(candidate, "https://mokaid.invalid");
  if (url.origin !== "https://mokaid.invalid") return accountEntryPath(desktopOnly);
  if (url.pathname === "/desktop/authorize") {
    const id = url.searchParams.get("request_id");
    return id && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)
      ? `/desktop/authorize?request_id=${encodeURIComponent(id)}`
      : accountEntryPath(desktopOnly);
  }
  if (ACCOUNT_LINKS.some((link) => link.path === url.pathname) || url.pathname === "/download") {
    if (url.pathname === "/account/billing" || url.pathname === "/account/spending") {
      const paymentReturn = new URL(
        legacyAccountDestination("/billing", url.search),
        "https://mokaid.invalid",
      );
      return `${url.pathname}${paymentReturn.search}`;
    }
    return url.pathname;
  }
  if (
    /^\/(dashboard|agents|tasks|projects|knowledge|drive|mail|calendar|analytics|settings|profile|members|integrations|billing)(\/[^?#]*)?$/.test(
      url.pathname,
    )
  ) {
    return desktopOnly
      ? legacyAccountDestination(url.pathname, url.search)
      : `${url.pathname}${url.pathname === "/billing" ? new URL(legacyAccountDestination("/billing", url.search), "https://mokaid.invalid").search : ""}`;
  }
  return accountEntryPath(desktopOnly);
}

export function authReturnFromSearch(search: string, desktopOnly = DESKTOP_ONLY_WEB): string {
  return safeAuthReturn(new URLSearchParams(search).get("returnTo"), desktopOnly);
}

export function localNavigation(destination: string): {
  to: string;
  search: Record<string, string>;
} {
  const url = new URL(destination, "https://mokaid.invalid");
  return { to: url.pathname, search: Object.fromEntries(url.searchParams) };
}
