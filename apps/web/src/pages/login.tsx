import { useState } from "react";
import { useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import { apiFetch } from "@/api/client";
import { useAuthStore } from "@/stores/auth-store";
import { Button } from "@/components/ui/button";
import { LogoMark } from "@/components/brand/logo";

const loginSchema = z.object({
  email: z.string().email("Enter a valid email"),
  password: z.string().min(1, "Password is required"),
});

type LoginForm = z.infer<typeof loginSchema>;

interface LoginResponse {
  token: string;
  user: { id: string; email: string; full_name: string; avatar_url: string | null };
}

interface MeResponse {
  user: LoginResponse["user"];
  workspaces: Array<{ id: string; name: string; slug: string; logo_url: string | null }>;
}

export function LoginPage() {
  const navigate = useNavigate();
  const setSession = useAuthStore((s) => s.setSession);
  const setWorkspaces = useAuthStore((s) => s.setWorkspaces);
  const [error, setError] = useState<string | null>(null);

  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<LoginForm>({
    resolver: zodResolver(loginSchema),
    defaultValues: { email: "tom@mokaid.dev", password: "" },
  });

  const onSubmit = async (values: LoginForm) => {
    setError(null);
    try {
      const response = await apiFetch<LoginResponse>("/api/auth/login", {
        method: "POST",
        body: values,
        skipWorkspace: true,
      });
      setSession(response.token, response.user);

      const me = await apiFetch<MeResponse>("/api/me", { skipWorkspace: true });
      setWorkspaces(me.workspaces);

      navigate({ to: "/" });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Login failed");
    }
  };

  return (
    <div className="flex h-full items-center justify-center bg-bg-deep p-4">
      <div className="absolute inset-0 overflow-hidden" aria-hidden>
        <div className="absolute -top-40 left-1/2 h-[500px] w-[700px] -translate-x-1/2 rounded-full bg-primary/10 blur-[120px]" />
      </div>

      <div className="relative w-full max-w-sm">
        <div className="mb-8 flex flex-col items-center gap-3">
          <LogoMark size={52} />
          <div className="text-center">
            <h1 className="text-2xl font-bold tracking-tight text-text">Welcome to mokaid</h1>
            <p className="mt-1 text-sm text-text-muted">Your AI workforce, in one workspace.</p>
          </div>
        </div>

        <form
          onSubmit={handleSubmit(onSubmit)}
          className="mk-card-raised space-y-4 p-6"
          noValidate
        >
          <div>
            <label htmlFor="email" className="mb-1.5 block text-xs font-medium text-text-secondary">
              Email
            </label>
            <input
              id="email"
              type="email"
              autoComplete="email"
              className="mk-input"
              placeholder="you@company.com"
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
              autoComplete="current-password"
              className="mk-input"
              placeholder="••••••••••"
              {...register("password")}
            />
            {errors.password && (
              <p className="mt-1 text-[11px] text-danger">{errors.password.message}</p>
            )}
          </div>

          {error && (
            <p className="rounded-md border border-danger/30 bg-danger-muted px-3 py-2 text-xs text-danger">
              {error}
            </p>
          )}

          <Button type="submit" size="lg" className="w-full" loading={isSubmitting}>
            Sign in
          </Button>

          <p className="text-center text-[11px] text-text-muted">
            Demo: tom@mokaid.dev / mokaid-dev-1234
          </p>
        </form>
      </div>
    </div>
  );
}
