import { useLayoutEffect, useRef, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { z } from "zod";
import { zodResolver } from "@hookform/resolvers/zod";
import gsap from "gsap";
import { ArrowLeft, Bot, CheckCircle2, Palette, Search, Sparkles } from "lucide-react";
import { apiFetch } from "@/api/client";
import { useAuthStore } from "@/stores/auth-store";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";

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

const agentCards = [
  {
    name: "Ava",
    role: "UI/UX Designer",
    activity: "Designing the onboarding flow",
    icon: Palette,
    tone: "bg-primary-muted text-primary-light",
    dot: "bg-success",
    status: "Active",
  },
  {
    name: "Liam",
    role: "Data Analyst",
    activity: "Analyzing weekly metrics",
    icon: Search,
    tone: "bg-info-muted text-info",
    dot: "bg-success",
    status: "Active",
  },
  {
    name: "Noah",
    role: "Developer",
    activity: "Shipped the API integration",
    icon: CheckCircle2,
    tone: "bg-success-muted text-success",
    dot: "bg-warning",
    status: "Busy",
  },
];

export function LoginPage() {
  const navigate = useNavigate();
  const setSession = useAuthStore((s) => s.setSession);
  const setWorkspaces = useAuthStore((s) => s.setWorkspaces);
  const [error, setError] = useState<string | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);

  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<LoginForm>({
    resolver: zodResolver(loginSchema),
    defaultValues: { email: "tom@mokaid.dev", password: "" },
  });

  useLayoutEffect(() => {
    const ctx = gsap.context(() => {
      gsap
        .timeline({ defaults: { ease: "power3.out" } })
        .from("[data-login-left]", { xPercent: -6, opacity: 0, duration: 0.7 })
        .from("[data-agent-card]", { y: 26, opacity: 0, stagger: 0.12, duration: 0.55 }, "-=0.3")
        .from("[data-login-form] > *", { y: 18, opacity: 0, stagger: 0.07, duration: 0.5 }, "-=0.5");
    }, rootRef);
    return () => ctx.revert();
  }, []);

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

      navigate({ to: "/dashboard" });
    } catch (err) {
      setError(err instanceof Error ? err.message : "Login failed");
    }
  };

  return (
    <div ref={rootRef} className="flex h-full bg-bg-deep">
      {/* Left panel: the agents */}
      <div
        data-login-left
        className="relative hidden w-[52%] overflow-hidden lg:block"
      >
        <img
          src="/desk-illustrations.png"
          alt=""
          aria-hidden
          className="absolute inset-0 h-full w-full object-cover"
        />
        <div
          className="absolute inset-0"
          style={{
            background:
              "linear-gradient(115deg, rgba(8,8,12,0.55) 0%, rgba(8,8,12,0.75) 55%, rgba(8,8,12,0.97) 100%)",
          }}
          aria-hidden
        />
        <div
          className="pointer-events-none absolute -bottom-24 -left-24 h-96 w-96 rounded-full bg-primary/20 blur-[120px]"
          aria-hidden
        />

        <div className="relative flex h-full flex-col justify-between p-10">
          <Link to="/" className="mk-focus-ring inline-flex w-fit items-center gap-2.5 rounded-md">
            <img src="/branding/logo-without-bg.png" alt="mokaid" className="h-9 w-9 object-contain" />
            <span className="text-lg font-bold tracking-tight text-white">mokaid</span>
          </Link>

          <div className="max-w-md space-y-6">
            <div className="space-y-3">
              {agentCards.map((agent) => {
                const Icon = agent.icon;
                return (
                  <div
                    key={agent.name}
                    data-agent-card
                    className="mk-glass flex items-center gap-3.5 rounded-lg border border-border/60 p-3.5 shadow-md"
                  >
                    <span
                      className={cn(
                        "flex h-10 w-10 shrink-0 items-center justify-center rounded-md",
                        agent.tone,
                      )}
                    >
                      <Icon size={18} />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="flex items-center gap-2 text-sm font-semibold text-text">
                        {agent.name}
                        <span className="text-[11px] font-normal text-text-muted">{agent.role}</span>
                      </span>
                      <span className="block truncate text-xs text-text-secondary">
                        {agent.activity}
                      </span>
                    </span>
                    <span className="flex items-center gap-1.5 text-[11px] text-text-muted">
                      <span className={cn("h-1.5 w-1.5 rounded-full", agent.dot)} />
                      {agent.status}
                    </span>
                  </div>
                );
              })}
            </div>

            <div>
              <h2 className="text-3xl font-bold leading-tight tracking-tight text-white">
                Your team is already
                <span className="mk-gradient-text block">at work.</span>
              </h2>
              <p className="mt-3 text-sm leading-relaxed text-text-secondary">
                AI agents and human teammates, one office, one flow. Sign in to see what
                they have been up to.
              </p>
            </div>
          </div>

          <p className="text-[11px] text-text-muted">
            The first platform for managing AI and real employees together.
          </p>
        </div>
      </div>

      {/* Right panel: the form */}
      <div className="relative flex flex-1 items-center justify-center p-6">
        <div
          className="pointer-events-none absolute inset-0 overflow-hidden"
          aria-hidden
        >
          <div className="absolute -top-40 left-1/2 h-[420px] w-[560px] -translate-x-1/2 rounded-full bg-primary/10 blur-[120px]" />
        </div>

        <Link
          to="/"
          className="mk-focus-ring absolute left-5 top-5 flex items-center gap-1.5 rounded-md px-2 py-1.5 text-xs text-text-muted transition-colors hover:text-text"
        >
          <ArrowLeft size={13} /> Back to site
        </Link>

        <div data-login-form className="relative w-full max-w-sm">
          <div className="mb-8 flex flex-col items-center gap-4 lg:items-start">
            <img
              src="/branding/logo-without-bg.png"
              alt="mokaid"
              className="h-12 w-12 object-contain lg:hidden"
            />
            <div className="text-center lg:text-left">
              <h1 className="text-[26px] font-bold tracking-tight text-text">Welcome back</h1>
              <p className="mt-1.5 text-sm text-text-muted">
                Sign in to your workspace and meet your agents.
              </p>
            </div>
          </div>

          <form onSubmit={handleSubmit(onSubmit)} className="space-y-4" noValidate>
            <div>
              <label
                htmlFor="email"
                className="mb-1.5 block text-xs font-medium text-text-secondary"
              >
                Email
              </label>
              <input
                id="email"
                type="email"
                autoComplete="email"
                className="mk-input h-11"
                placeholder="you@company.com"
                {...register("email")}
              />
              {errors.email && (
                <p className="mt-1 text-[11px] text-danger">{errors.email.message}</p>
              )}
            </div>

            <div>
              <label
                htmlFor="password"
                className="mb-1.5 block text-xs font-medium text-text-secondary"
              >
                Password
              </label>
              <input
                id="password"
                type="password"
                autoComplete="current-password"
                className="mk-input h-11"
                placeholder="Your password"
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

            <Button type="submit" size="lg" className="w-full shadow-glow" loading={isSubmitting}>
              Sign in
            </Button>
          </form>

          <div className="mt-6 rounded-md border border-border bg-surface px-4 py-3">
            <p className="flex items-center gap-2 text-[11px] text-text-muted">
              <Sparkles size={12} className="text-primary-light" />
              Demo access: tom@mokaid.dev / mokaid-dev-1234
            </p>
          </div>

          <p className="mt-6 flex items-center justify-center gap-1.5 text-[11px] text-text-muted lg:justify-start">
            <Bot size={12} />
            Your agents kept working while you were away.
          </p>
        </div>
      </div>
    </div>
  );
}
