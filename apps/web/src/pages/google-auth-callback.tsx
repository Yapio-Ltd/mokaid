import { useEffect, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { CheckCircle2, Loader2, XCircle } from "lucide-react";
import { apiFetch } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Logo } from "@/components/brand/logo";
import { googleAuthRedirectUri } from "@/components/auth/google-sign-in-button";
import { waitForAuthHydration } from "@/lib/oauth-callback";
import { useAuthStore } from "@/stores/auth-store";

type Status = "working" | "success" | "error";

interface GoogleAuthResponse {
  token: string;
  user: {
    id: string;
    email: string;
    full_name: string;
    avatar_url: string | null;
    has_password?: boolean;
  };
  status: "created" | "existing";
  workspaces: Array<{
    id: string;
    name: string;
    slug: string;
    logo_url: string | null;
    role_name?: string;
  }>;
}

/** Completes Google identity OAuth (login / signup), not integrations. */
export function GoogleAuthCallbackPage() {
  const navigate = useNavigate();
  const establishSession = useAuthStore((s) => s.establishSession);

  const [status, setStatus] = useState<Status>("working");
  const [message, setMessage] = useState("Signing you in with Google…");

  useEffect(() => {
    let cancelled = false;

    async function finalize() {
      await waitForAuthHydration();
      if (cancelled) return;

      const params = new URLSearchParams(window.location.search);
      const code = params.get("code");
      const state = params.get("state");
      const oauthError = params.get("error_description") || params.get("error");

      if (oauthError) {
        setStatus("error");
        setMessage(oauthError);
        return;
      }

      if (!code || !state) {
        setStatus("error");
        setMessage("Google did not return an authorization code.");
        return;
      }

      const dedupeKey = `google_auth:${code}`;
      if (sessionStorage.getItem(dedupeKey) === "done") {
        navigate({ to: "/dashboard" });
        return;
      }

      try {
        const result = await apiFetch<GoogleAuthResponse>("/api/auth/google/callback", {
          method: "POST",
          body: {
            code,
            state,
            redirect_uri: googleAuthRedirectUri(),
          },
          skipWorkspace: true,
        });

        if (cancelled) return;

        sessionStorage.setItem(dedupeKey, "done");
        establishSession(result.token, result.user, result.workspaces ?? []);

        if (!result.workspaces?.length) {
          setStatus("error");
          setMessage("Signed in, but no workspace is available. Please contact support.");
          return;
        }

        setStatus("success");
        setMessage(
          result.status === "created"
            ? "Welcome! Your workspace is ready."
            : "Signed in. Taking you to your workspace…",
        );
        navigate({ to: "/dashboard" });
      } catch (err) {
        if (cancelled) return;
        setStatus("error");
        setMessage(err instanceof Error ? err.message : "Google sign-in failed.");
      }
    }

    finalize();
    return () => {
      cancelled = true;
    };
  }, [navigate, establishSession]);

  return (
    <div className="flex h-full flex-col items-center justify-center gap-6 bg-bg-deep px-6">
      <Logo />
      <div className="mk-neon-panel flex w-full max-w-sm flex-col items-center gap-4 p-8 text-center">
        {status === "working" && <Loader2 size={28} className="animate-spin text-primary-light" />}
        {status === "success" && <CheckCircle2 size={28} className="text-success" />}
        {status === "error" && <XCircle size={28} className="text-danger" />}
        <div>
          <h1 className="text-sm font-bold text-text">Google sign-in</h1>
          <p className="mt-1.5 text-xs leading-relaxed text-text-secondary">{message}</p>
        </div>
        {status === "error" && (
          <Link to="/login">
            <Button size="sm" variant="secondary">
              Back to sign in
            </Button>
          </Link>
        )}
      </div>
    </div>
  );
}
