import { useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import { ArrowLeft, Bot, Building2, Sparkles } from "lucide-react";
import { apiFetch } from "@/api/client";
import { useAuthStore } from "@/stores/auth-store";
import { Button } from "@/components/ui/button";

const signupSchema = z.object({
  full_name: z.string().min(2, "Tell us your name"),
  email: z.string().email("Enter a valid email"),
  password: z.string().min(10, "At least 10 characters"),
  workspace_name: z.string().optional(),
});

type SignupForm = z.infer<typeof signupSchema>;

interface RegisterResponse {
  token: string;
  user: { id: string; email: string; full_name: string; avatar_url: string | null };
  workspace: { id: string; name: string; slug: string; logo_url: string | null };
}

export function SignupPage() {
  const navigate = useNavigate();
  const setSession = useAuthStore((s) => s.setSession);
  const setWorkspaces = useAuthStore((s) => s.setWorkspaces);
  const [error, setError] = useState<string | null>(null);

  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<SignupForm>({ resolver: zodResolver(signupSchema) });

  const onSubmit = async (values: SignupForm) => {
    setError(null);
    try {
      const response = await apiFetch<RegisterResponse>("/api/auth/register", {
        method: "POST",
        body: values,
        skipWorkspace: true,
      });
      setSession(response.token, response.user);
      setWorkspaces([{ ...response.workspace, role_name: "Owner" } as never]);
      navigate({ to: "/dashboard" });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Signup failed");
    }
  };

  return (
    <div className="relative flex h-full items-center justify-center bg-bg-deep p-6">
      <div className="pointer-events-none absolute inset-0 overflow-hidden" aria-hidden>
        <div className="absolute -top-40 left-1/2 h-[420px] w-[560px] -translate-x-1/2 rounded-full bg-primary/10 blur-[120px]" />
      </div>

      <Link
        to="/"
        className="mk-focus-ring absolute left-5 top-5 flex items-center gap-1.5 rounded-md px-2 py-1.5 text-xs text-text-muted transition-colors hover:text-text"
      >
        <ArrowLeft size={13} /> Back to site
      </Link>

      <div className="relative w-full max-w-sm mk-fade-up">
        <div className="mb-8 flex flex-col items-center gap-4">
          <img
            src="/branding/logo-without-bg.png"
            alt="mokaid"
            className="h-12 w-12 object-contain"
          />
          <div className="text-center">
            <h1 className="text-[26px] font-bold tracking-tight text-text">
              Create your workspace
            </h1>
            <p className="mt-1.5 text-sm text-text-muted">
              You'll be guided step by step — your first agent is 2 minutes away.
            </p>
          </div>
        </div>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4" noValidate>
          <div>
            <label htmlFor="full_name" className="mb-1.5 block text-xs font-medium text-text-secondary">
              Your name
            </label>
            <input
              id="full_name"
              className="mk-input h-11"
              placeholder="Ada Lovelace"
              autoComplete="name"
              {...register("full_name")}
            />
            {errors.full_name && (
              <p className="mt-1 text-[11px] text-danger">{errors.full_name.message}</p>
            )}
          </div>

          <div>
            <label htmlFor="email" className="mb-1.5 block text-xs font-medium text-text-secondary">
              Work email
            </label>
            <input
              id="email"
              type="email"
              className="mk-input h-11"
              placeholder="you@company.com"
              autoComplete="email"
              {...register("email")}
            />
            {errors.email && <p className="mt-1 text-[11px] text-danger">{errors.email.message}</p>}
          </div>

          <div>
            <label htmlFor="password" className="mb-1.5 block text-xs font-medium text-text-secondary">
              Password
            </label>
            <input
              id="password"
              type="password"
              className="mk-input h-11"
              placeholder="10+ characters"
              autoComplete="new-password"
              {...register("password")}
            />
            {errors.password && (
              <p className="mt-1 text-[11px] text-danger">{errors.password.message}</p>
            )}
          </div>

          <div>
            <label
              htmlFor="workspace_name"
              className="mb-1.5 flex items-center gap-1.5 text-xs font-medium text-text-secondary"
            >
              <Building2 size={12} /> Company or team name
              <span className="font-normal text-text-muted">(optional)</span>
            </label>
            <input
              id="workspace_name"
              className="mk-input h-11"
              placeholder="Acme Inc."
              {...register("workspace_name")}
            />
          </div>

          {error && (
            <p className="rounded-md border border-danger/30 bg-danger-muted px-3 py-2 text-xs text-danger">
              {error}
            </p>
          )}

          <Button type="submit" size="lg" className="w-full shadow-glow" loading={isSubmitting}>
            <Sparkles size={15} /> Create workspace
          </Button>
        </form>

        <p className="mt-6 text-center text-xs text-text-muted">
          Already have an account?{" "}
          <Link to="/login" className="text-primary-light hover:underline">
            Sign in
          </Link>
        </p>

        <p className="mt-6 flex items-center justify-center gap-1.5 text-[11px] text-text-muted">
          <Bot size={12} />
          Your first AI teammate is waiting to meet you.
        </p>
      </div>
    </div>
  );
}
