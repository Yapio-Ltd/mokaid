import { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { CheckCircle2, Loader2, XCircle } from "lucide-react";
import { useGithubOauthCallback } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Logo } from "@/components/brand/logo";
import { useAuthStore } from "@/stores/auth-store";
import {
  completeOauthInPopup,
  consumeOauthReturn,
  notifyOauthOpener,
  oauthDedupeKey,
  runOauthOnce,
  waitForAuthHydration,
} from "@/lib/oauth-callback";

type Status = "working" | "success" | "error";

export function GithubCallbackPage() {
  const navigate = useNavigate();
  const callback = useGithubOauthCallback();
  const mutateAsyncRef = useRef(callback.mutateAsync);
  mutateAsyncRef.current = callback.mutateAsync;

  const [status, setStatus] = useState<Status>("working");
  const [message, setMessage] = useState("Finalizing the GitHub connection…");

  useEffect(() => {
    let cancelled = false;

    async function finalize() {
      await waitForAuthHydration();
      if (cancelled) return;

      const params = new URLSearchParams(window.location.search);
      const code = params.get("code");
      const state = params.get("state");
      const token = useAuthStore.getState().token;

      if (!token) {
        setStatus("error");
        setMessage("You must be signed in to complete the GitHub connection.");
        return;
      }

      if (!code || !state) {
        setStatus("error");
        setMessage(params.get("error_description") ?? "GitHub did not return an authorization code.");
        return;
      }

      const dedupeKey = oauthDedupeKey("github", code);
      if (sessionStorage.getItem(dedupeKey) === "done") {
        if (notifyOauthOpener("github")) {
          window.close();
        } else {
          navigate({ to: consumeOauthReturn() });
        }
        return;
      }

      try {
        const result = await runOauthOnce(dedupeKey, () =>
          mutateAsyncRef.current({
            code,
            state,
            redirect_uri: `${window.location.origin}/oauth/github/callback`,
          }),
        );

        sessionStorage.setItem(dedupeKey, "done");
        if (cancelled) return;

        setStatus("success");
        const account = result.data.connected_account;
        completeOauthInPopup(
          "github",
          account ? `@${account}` : undefined,
          (to) => navigate({ to }),
          setMessage,
        );
      } catch {
        if (cancelled) return;
        setStatus("error");
        setMessage("The authorization could not be completed. Please try connecting again.");
      }
    }

    finalize();

    return () => {
      cancelled = true;
    };
  }, [navigate]);

  const returnTo = sessionStorage.getItem("oauth_return_to") ?? "/dashboard";

  return (
    <div className="flex h-full flex-col items-center justify-center gap-6 bg-bg-deep px-6">
      <Logo />
      <div className="mk-neon-panel flex w-full max-w-sm flex-col items-center gap-4 p-8 text-center">
        {status === "working" && <Loader2 size={28} className="animate-spin text-primary-light" />}
        {status === "success" && <CheckCircle2 size={28} className="text-success" />}
        {status === "error" && <XCircle size={28} className="text-danger" />}
        <div>
          <h1 className="text-sm font-bold text-text">GitHub connection</h1>
          <p className="mt-1.5 text-xs leading-relaxed text-text-secondary">{message}</p>
        </div>
        {status === "error" && (
          <Link to={returnTo}>
            <Button size="sm" variant="secondary">
              Back to onboarding
            </Button>
          </Link>
        )}
      </div>
    </div>
  );
}
