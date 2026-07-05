import { useEffect, useRef, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { CheckCircle2, Loader2, XCircle } from "lucide-react";
import { useGoogleOauthCallback } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Logo } from "@/components/brand/logo";
import { useAuthStore } from "@/stores/auth-store";

type Status = "working" | "success" | "error";

export function GoogleCallbackPage() {
  const navigate = useNavigate();
  const callback = useGoogleOauthCallback();
  const token = useAuthStore((s) => s.token);
  const [status, setStatus] = useState<Status>("working");
  const [message, setMessage] = useState("Finalizing the Google connection…");
  const startedRef = useRef(false);

  useEffect(() => {
    if (startedRef.current) return;
    startedRef.current = true;

    const params = new URLSearchParams(window.location.search);
    const code = params.get("code");
    const state = params.get("state");

    if (!token) {
      setStatus("error");
      setMessage("You must be signed in to complete the Google connection.");
      return;
    }

    if (!code || !state) {
      setStatus("error");
      setMessage(params.get("error_description") ?? "Google did not return an authorization code.");
      return;
    }

    callback.mutate(
      {
        code,
        state,
        redirect_uri: `${window.location.origin}/oauth/google/callback`,
      },
      {
        onSuccess: (result) => {
          setStatus("success");
          const account = result.data.connected_account;
          setMessage(
            account
              ? `Connected as ${account}. Google Drive, Gmail and other tools are ready. Redirecting…`
              : "Google is connected. Redirecting to integrations…",
          );
          setTimeout(() => navigate({ to: "/integrations" }), 1800);
        },
        onError: () => {
          setStatus("error");
          setMessage("The authorization could not be completed. Please try connecting again.");
        },
      },
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <div className="flex h-full flex-col items-center justify-center gap-6 bg-bg-deep px-6">
      <Logo />
      <div className="mk-card-raised flex w-full max-w-sm flex-col items-center gap-4 p-8 text-center">
        {status === "working" && <Loader2 size={28} className="animate-spin text-primary-light" />}
        {status === "success" && <CheckCircle2 size={28} className="text-success" />}
        {status === "error" && <XCircle size={28} className="text-danger" />}
        <div>
          <h1 className="text-sm font-bold text-text">Google connection</h1>
          <p className="mt-1.5 text-xs leading-relaxed text-text-secondary">{message}</p>
        </div>
        {status === "error" && (
          <Link to="/integrations">
            <Button size="sm" variant="secondary">
              Back to integrations
            </Button>
          </Link>
        )}
      </div>
    </div>
  );
}
