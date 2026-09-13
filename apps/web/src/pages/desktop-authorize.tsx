import { useEffect, useState } from "react";
import { Link } from "@tanstack/react-router";
import { CheckCircle2, ExternalLink, Loader2, Monitor, ShieldCheck } from "lucide-react";
import { apiFetch } from "@/api/client";
import { Logo } from "@/components/brand/logo";
import { Button } from "@/components/ui/button";
import { useAuthStore, type AuthUser } from "@/stores/auth-store";

interface DesktopRequest {
  request_id: string;
  application: string;
  redirect_uri: string;
  expires_at: string;
  user: AuthUser;
}

/** Browser-only consent. Session credentials never enter a redirect URL. */
export function DesktopAuthorizePage() {
  const token = useAuthStore((state) => state.token);
  const [request, setRequest] = useState<DesktopRequest | null>(null);
  const [loading, setLoading] = useState(false);
  const [approved, setApproved] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const requestId = new URLSearchParams(window.location.search).get("request_id");
  const validId =
    requestId != null &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(requestId);

  useEffect(() => {
    // Sign-in stays in the existing login flow; hydrate after its tab updates
    // shared auth storage, or when the user returns to this consent tab.
    const syncAuth = () => {
      void useAuthStore.persist.rehydrate();
    };
    const onStorage = (event: globalThis.StorageEvent) => {
      if (event.key === "mokaid-auth") syncAuth();
    };
    window.addEventListener("storage", onStorage);
    window.addEventListener("focus", syncAuth);
    syncAuth();
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener("focus", syncAuth);
    };
  }, []);

  useEffect(() => {
    let active = true;
    setRequest(null);
    setError(null);
    if (!token || !validId) return;
    setLoading(true);
    apiFetch<{ data: DesktopRequest }>(`/api/desktop/auth/requests/${requestId}`, {
      skipWorkspace: true,
    })
      .then(({ data }) => {
        if (active) setRequest(data);
      })
      .catch((failure: unknown) => {
        if (active)
          setError(
            failure instanceof Error
              ? failure.message
              : "This connection request is no longer available.",
          );
      })
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [token, requestId, validId]);

  const approve = async () => {
    if (!request || loading) return;
    setLoading(true);
    setError(null);
    try {
      const { data } = await apiFetch<{ data: { redirect_url: string } }>(
        `/api/desktop/auth/requests/${request.request_id}/approve`,
        { method: "POST", body: {}, skipWorkspace: true },
      );
      const callback = new URL(data.redirect_url);
      const expected = new URL(request.redirect_uri);
      const keys = [...callback.searchParams.keys()];
      if (
        callback.protocol !== "http:" ||
        callback.hostname !== "127.0.0.1" ||
        callback.origin !== expected.origin ||
        callback.pathname !== "/callback" ||
        callback.username ||
        callback.password ||
        callback.hash ||
        keys.length !== 2 ||
        !callback.searchParams.get("code") ||
        !callback.searchParams.get("state") ||
        keys.some((key) => key !== "code" && key !== "state")
      )
        throw new Error(
          "The desktop callback address is invalid. Restart sign-in from Mokaid Desktop.",
        );
      setApproved(true);
      // Top-level navigation (not fetch) reaches the loopback listener without
      // granting a web page access to arbitrary local network resources.
      window.location.assign(callback.href);
    } catch (failure) {
      setError(
        failure instanceof Error
          ? failure.message
          : "Connection failed. Start again from Mokaid Desktop.",
      );
      setLoading(false);
    }
  };

  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-6 bg-bg-deep px-6 py-12">
      <Logo />
      <section className="mk-neon-panel w-full max-w-md p-8" aria-labelledby="desktop-title">
        <Monitor className="mb-5 text-primary-light" size={30} aria-hidden />
        <h1 id="desktop-title" className="text-xl font-semibold text-text">
          Connect Mokaid Desktop
        </h1>
        <p className="mt-3 text-sm leading-relaxed text-text-secondary">
          Authorize the Mokaid application on this computer to access your account and workspaces.
        </p>
        {!validId ? (
          <p role="alert" className="mt-5 text-sm text-danger">
            This link is invalid. Start sign-in from Mokaid Desktop.
          </p>
        ) : !token ? (
          <div className="mt-6 space-y-4">
            <p className="text-sm text-text-secondary">
              Sign in to your account, then confirm this desktop connection.
            </p>
            <a
              href={`/login?returnTo=${encodeURIComponent(`/desktop/authorize?request_id=${requestId}`)}`}
              className="mk-focus-ring inline-flex items-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-medium text-white"
            >
              Sign in to Mokaid <ExternalLink size={14} aria-hidden />
            </a>
          </div>
        ) : approved ? (
          <p role="status" className="mt-6 flex items-center gap-2 text-sm text-success">
            <CheckCircle2 size={18} /> Returning to Mokaid Desktop…
          </p>
        ) : (
          <div className="mt-6 space-y-5">
            {loading && !request && (
              <p role="status" className="flex items-center gap-2 text-sm text-text-muted">
                <Loader2 size={16} className="animate-spin" /> Checking the request…
              </p>
            )}
            {request && (
              <>
                <div className="rounded-md border border-white/10 bg-white/5 p-4">
                  <p className="text-sm font-medium text-text">{request.user.full_name}</p>
                  <p className="mt-1 break-all text-sm text-text-muted">{request.user.email}</p>
                </div>
                <p className="flex gap-2 text-xs leading-relaxed text-text-muted">
                  <ShieldCheck size={18} className="shrink-0" aria-hidden />
                  Continue only if you just started sign-in in Mokaid Desktop on this computer. This
                  request expires after five minutes.
                </p>
                <Button onClick={() => void approve()} disabled={loading} className="w-full">
                  {loading ? "Connecting…" : "Connect this computer"}
                </Button>
              </>
            )}
          </div>
        )}
        {error && (
          <p role="alert" className="mt-5 text-sm leading-relaxed text-danger">
            {error}
          </p>
        )}
        <Link
          to="/"
          className="mk-focus-ring mt-6 inline-block rounded text-xs text-text-muted hover:text-text"
        >
          Cancel and return to Mokaid
        </Link>
      </section>
    </main>
  );
}
