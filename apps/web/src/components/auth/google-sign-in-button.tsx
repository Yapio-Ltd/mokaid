import { useState } from "react";
import { apiFetch } from "@/api/client";
import { Button } from "@/components/ui/button";
import { GoogleLogo } from "@/components/brand/google-logo";

interface GoogleSignInButtonProps {
  intent?: "login" | "signup";
  label?: string;
  className?: string;
  onError?: (message: string) => void;
}

const AUTH_CALLBACK_PATH = "/auth/google/callback";

export function googleAuthRedirectUri(): string {
  return `${window.location.origin}${AUTH_CALLBACK_PATH}`;
}

/** Continues to Google OAuth for identity (sign in / sign up). */
export function GoogleSignInButton({
  intent = "login",
  label,
  className,
  onError,
}: GoogleSignInButtonProps) {
  const [loading, setLoading] = useState(false);
  const text =
    label ?? (intent === "signup" ? "Continue with Google" : "Sign in with Google");

  const start = async () => {
    setLoading(true);
    try {
      const redirectUri = googleAuthRedirectUri();
      sessionStorage.setItem("google_auth_intent", intent);
      sessionStorage.setItem("google_auth_return", window.location.pathname);

      const res = await apiFetch<{ data: { authorize_url: string } }>("/api/auth/google/start", {
        method: "POST",
        body: { redirect_uri: redirectUri, intent },
        skipWorkspace: true,
      });
      window.location.assign(res.data.authorize_url);
    } catch (err) {
      setLoading(false);
      onError?.(err instanceof Error ? err.message : "Google sign-in is unavailable");
    }
  };

  return (
    <Button
      type="button"
      variant="secondary"
      size="lg"
      className={className ?? "w-full"}
      loading={loading}
      onClick={start}
    >
      {!loading && <GoogleLogo />}
      {text}
    </Button>
  );
}
