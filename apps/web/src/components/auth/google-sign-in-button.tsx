import { useState } from "react";
import { apiFetch } from "@/api/client";
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
    <button
      type="button"
      disabled={loading}
      onClick={start}
      className={
        className ??
        "mk-focus-ring inline-flex h-11 w-full select-none items-center justify-center gap-3 rounded-md border border-white/20 bg-white px-5 text-sm font-medium text-[#1f1f1f] shadow-sm transition-all duration-200 hover:bg-[#f7f7f7] active:scale-[0.97] disabled:pointer-events-none disabled:opacity-50"
      }
    >
      {loading ? (
        <span className="h-4 w-4 animate-spin rounded-full border-2 border-[#1f1f1f]/40 border-t-[#1f1f1f]" />
      ) : (
        <GoogleLogo />
      )}
      {text}
    </button>
  );
}
