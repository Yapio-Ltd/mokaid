import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Link } from "@tanstack/react-router";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import {
  ArrowRight,
  BarChart3,
  Bot,
  CalendarDays,
  CheckCircle2,
  CreditCard,
  Library,
  Plug,
  ShieldCheck,
  Sparkles,
  Users,
  Zap,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { useSmoothScroll } from "@/lib/use-smooth-scroll";
import { useAuthStore } from "@/stores/auth-store";
import { Button } from "@/components/ui/button";

gsap.registerPlugin(ScrollTrigger);

const showcaseSteps = [
  {
    id: "dashboard",
    image: "/images/dashboard.png",
    icon: Bot,
    kicker: "Live workspace",
    title: "See your whole team at a glance",
    description:
      "A real time 3D office where every AI and human agent is visible, with status, current task and performance. Click anyone to open their full profile.",
  },
  {
    id: "agents",
    image: "/images/agents.png",
    icon: Users,
    kicker: "Agent management",
    title: "Hire, brief and grow your agents",
    description:
      "AI agents, human linked agents and hybrids live side by side. Skills, levels, teams and performance tracking, all in one clean directory.",
  },
  {
    id: "tasks",
    image: "/images/tasks.png",
    icon: CheckCircle2,
    kicker: "Task orchestration",
    title: "Work flows through a living board",
    description:
      "Kanban, list and timeline views with live progress from every agent. Assign work to an AI the same way you assign it to a person.",
  },
  {
    id: "analytics",
    image: "/images/analytics.png",
    icon: BarChart3,
    kicker: "Analytics",
    title: "Measure output, not presence",
    description:
      "Throughput, completion rates and agent performance over time. Know exactly what your hybrid workforce delivers every week.",
  },
  {
    id: "knowledge",
    image: "/images/knowledge.png",
    icon: Library,
    kicker: "Shared knowledge",
    title: "One brain for the whole team",
    description:
      "Docs, guidelines and briefs that agents actually read. Your AI teammates stay on brand and on context, automatically.",
  },
];

const featureCards = [
  {
    icon: Bot,
    title: "AI and human, one roster",
    description: "Manage autonomous agents and real teammates with the same tools, roles and rituals.",
  },
  {
    icon: Zap,
    title: "Real time everything",
    description: "Presence, task progress and notifications stream live over websockets. No refresh, ever.",
  },
  {
    icon: CalendarDays,
    title: "A calendar that breathes",
    description: "Deadlines, meetings and time off in a calm, minimal view designed for focus.",
  },
  {
    icon: Plug,
    title: "Plugs into your stack",
    description: "Slack, GitHub, Notion, Figma and more. Your agents work where your work already lives.",
  },
  {
    icon: CreditCard,
    title: "Usage based billing",
    description: "Pay for the work your agents deliver. Transparent usage, clear invoices, zero surprises.",
  },
  {
    icon: ShieldCheck,
    title: "Enterprise grade security",
    description: "Workspace isolation, scoped tokens and full audit trails, from day one.",
  },
];

const marqueeItems = [
  "AI employees",
  "Human teammates",
  "Live 3D office",
  "Task orchestration",
  "Shared knowledge",
  "Real time analytics",
  "Smart calendar",
  "Integrations",
];

const stats = [
  { value: 12, suffix: "+", label: "Agent roles out of the box" },
  { value: 87, suffix: "%", label: "Average team efficiency score" },
  { value: 24, suffix: "/7", label: "Your AI workforce never sleeps" },
  { value: 3, suffix: "min", label: "From signup to first agent" },
];

function LandingLogo() {
  return (
    <span className="flex items-center gap-2.5">
      <img src="/branding/logo-without-bg.png" alt="mokaid" className="h-8 w-8 object-contain" />
      <span className="text-[17px] font-bold tracking-tight text-text">mokaid</span>
    </span>
  );
}

export function LandingPage() {
  useSmoothScroll();

  const rootRef = useRef<HTMLDivElement>(null);
  const heroImageRef = useRef<HTMLDivElement>(null);
  const [activeStep, setActiveStep] = useState(0);
  const token = useAuthStore((s) => s.token);

  useEffect(() => {
    // The landing page owns the scroll; the app shell uses inner scrolling.
    document.documentElement.style.overflowY = "auto";
    return () => {
      document.documentElement.style.overflowY = "";
    };
  }, []);

  useLayoutEffect(() => {
    const ctx = gsap.context(() => {
      // Hero entrance
      gsap
        .timeline({ defaults: { ease: "power3.out" } })
        .from("[data-hero-badge]", { y: 20, opacity: 0, duration: 0.6 })
        .from(
          "[data-hero-line]",
          { y: 42, opacity: 0, duration: 0.8, stagger: 0.12 },
          "-=0.3",
        )
        .from("[data-hero-sub]", { y: 24, opacity: 0, duration: 0.6 }, "-=0.45")
        .from("[data-hero-cta]", { y: 18, opacity: 0, duration: 0.5, stagger: 0.08 }, "-=0.35")
        .from(
          heroImageRef.current,
          { y: 80, opacity: 0, scale: 0.96, duration: 1 },
          "-=0.4",
        )
        .from("[data-hero-chip]", { y: 24, opacity: 0, stagger: 0.12, duration: 0.5 }, "-=0.5");

      // Hero parallax
      gsap.to(heroImageRef.current, {
        yPercent: -8,
        ease: "none",
        scrollTrigger: {
          trigger: heroImageRef.current,
          start: "top bottom",
          end: "bottom top",
          scrub: true,
        },
      });

      // Generic reveal for sections
      gsap.utils.toArray<HTMLElement>("[data-reveal]").forEach((el) => {
        gsap.from(el, {
          y: 28,
          opacity: 0,
          duration: 0.7,
          ease: "power3.out",
          scrollTrigger: { trigger: el, start: "top 86%" },
        });
      });

      // Stat counters
      gsap.utils.toArray<HTMLElement>("[data-count]").forEach((el) => {
        const target = Number(el.dataset.count ?? 0);
        const state = { v: 0 };
        gsap.to(state, {
          v: target,
          duration: 1.4,
          ease: "power2.out",
          scrollTrigger: { trigger: el, start: "top 88%" },
          onUpdate: () => {
            el.textContent = String(Math.round(state.v));
          },
        });
      });

      // Scrollytelling steps drive the sticky screenshot
      gsap.utils.toArray<HTMLElement>("[data-step]").forEach((el, i) => {
        ScrollTrigger.create({
          trigger: el,
          start: "top 55%",
          end: "bottom 55%",
          onToggle: (self) => {
            if (self.isActive) setActiveStep(i);
          },
        });
      });
    }, rootRef);

    return () => ctx.revert();
  }, []);

  return (
    <div ref={rootRef} className="min-h-full bg-bg-deep text-text">
      {/* Nav */}
      <header className="fixed inset-x-0 top-0 z-50 border-b border-border/50 mk-glass">
        <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-5">
          <Link to="/" className="mk-focus-ring rounded-md">
            <LandingLogo />
          </Link>
          <nav className="hidden items-center gap-7 text-[13px] font-medium text-text-secondary md:flex">
            <a href="#product" className="transition-colors hover:text-text">
              Product
            </a>
            <a href="#features" className="transition-colors hover:text-text">
              Features
            </a>
            <a href="#stats" className="transition-colors hover:text-text">
              Why mokaid
            </a>
          </nav>
          <div className="flex items-center gap-2.5">
            {token ? (
              <Link to="/dashboard">
                <Button size="sm">
                  Open app <ArrowRight size={14} />
                </Button>
              </Link>
            ) : (
              <>
                <Link to="/login">
                  <Button variant="ghost" size="sm">
                    Sign in
                  </Button>
                </Link>
                <Link to="/login">
                  <Button size="sm">
                    Get started <ArrowRight size={14} />
                  </Button>
                </Link>
              </>
            )}
          </div>
        </div>
      </header>

      {/* Hero */}
      <section className="relative overflow-hidden px-5 pb-24 pt-36">
        <div
          className="pointer-events-none absolute inset-0"
          aria-hidden
        >
          <div className="absolute -top-48 left-1/2 h-[560px] w-[880px] -translate-x-1/2 rounded-full bg-primary/15 blur-[140px]" />
          <div className="absolute bottom-0 left-[8%] h-72 w-72 rounded-full bg-info/10 blur-[120px]" />
        </div>

        <div className="relative mx-auto max-w-4xl text-center">
          <span
            data-hero-badge
            className="inline-flex items-center gap-2 rounded-full border border-primary/25 bg-primary-muted px-4 py-1.5 text-xs font-medium text-primary-light"
          >
            <Sparkles size={13} />
            The first OS for AI and human employees
          </span>

          <h1 className="mt-7 text-5xl font-bold leading-[1.06] tracking-tight md:text-[68px]">
            <span data-hero-line className="block">
              Your workforce,
            </span>
            <span data-hero-line className="mk-gradient-text block pb-2">
              humans and AI together.
            </span>
          </h1>

          <p data-hero-sub className="mx-auto mt-6 max-w-xl text-base text-text-secondary md:text-lg">
            mokaid is the workspace where AI agents and real teammates share the same office,
            the same tasks and the same goals. Hire an agent in minutes, watch it work in real time.
          </p>

          <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
            <span data-hero-cta>
              <Link to="/login">
                <Button size="lg" className="px-7 shadow-glow">
                  Start for free <ArrowRight size={16} />
                </Button>
              </Link>
            </span>
            <span data-hero-cta>
              <a href="#product">
                <Button variant="secondary" size="lg" className="px-7">
                  See the product
                </Button>
              </a>
            </span>
          </div>
        </div>

        {/* Hero visual */}
        <div ref={heroImageRef} className="relative mx-auto mt-16 max-w-5xl">
          <div className="absolute -inset-6 rounded-2xl bg-primary/20 opacity-40 blur-3xl" aria-hidden />
          <div className="relative overflow-hidden rounded-2xl border border-border-strong/60 shadow-lg">
            <img
              src="/desk-illustrations.png"
              alt="The mokaid virtual office with AI and human agents working at their desks"
              className="w-full object-cover"
            />
            <div className="absolute inset-0 bg-gradient-to-t from-bg-deep/60 via-transparent to-transparent" aria-hidden />
          </div>

          <div
            data-hero-chip
            className="mk-glass mk-float absolute -left-3 top-10 hidden items-center gap-2.5 rounded-lg border border-border/60 px-3.5 py-2.5 shadow-md md:flex"
          >
            <span className="flex h-8 w-8 items-center justify-center rounded-md bg-primary-muted text-primary-light">
              <Bot size={16} />
            </span>
            <span>
              <span className="block text-xs font-semibold">Ava is designing</span>
              <span className="block text-[11px] text-text-muted">Landing page, 75% done</span>
            </span>
          </div>

          <div
            data-hero-chip
            className="mk-glass mk-float absolute -right-3 top-1/3 hidden items-center gap-2.5 rounded-lg border border-border/60 px-3.5 py-2.5 shadow-md md:flex"
            style={{ animationDelay: "1.2s" }}
          >
            <span className="flex h-8 w-8 items-center justify-center rounded-md bg-success-muted text-success">
              <CheckCircle2 size={16} />
            </span>
            <span>
              <span className="block text-xs font-semibold">Task completed</span>
              <span className="block text-[11px] text-text-muted">Market research by Liam</span>
            </span>
          </div>

          <div
            data-hero-chip
            className="mk-glass mk-float absolute bottom-8 left-10 hidden items-center gap-2.5 rounded-lg border border-border/60 px-3.5 py-2.5 shadow-md md:flex"
            style={{ animationDelay: "2.1s" }}
          >
            <span className="flex h-8 w-8 items-center justify-center rounded-md bg-info-muted text-info">
              <Users size={16} />
            </span>
            <span>
              <span className="block text-xs font-semibold">12 agents online</span>
              <span className="block text-[11px] text-text-muted">8 working, 2 in a meeting</span>
            </span>
          </div>
        </div>
      </section>

      {/* Marquee */}
      <section className="border-y border-border/50 bg-bg py-5" aria-hidden>
        <div className="overflow-hidden">
          <div className="mk-marquee flex w-max items-center gap-10">
            {[...marqueeItems, ...marqueeItems].map((item, i) => (
              <span key={i} className="flex items-center gap-10 text-sm font-medium text-text-muted">
                {item}
                <span className="h-1 w-1 rounded-full bg-primary/60" />
              </span>
            ))}
          </div>
        </div>
      </section>

      {/* Stats */}
      <section id="stats" className="px-5 py-24">
        <div className="mx-auto grid max-w-5xl grid-cols-2 gap-6 md:grid-cols-4">
          {stats.map((stat) => (
            <div key={stat.label} data-reveal className="text-center">
              <p className="text-4xl font-bold tracking-tight text-text md:text-5xl">
                <span data-count={stat.value}>0</span>
                <span className="text-primary-light">{stat.suffix}</span>
              </p>
              <p className="mt-2 text-xs text-text-muted md:text-sm">{stat.label}</p>
            </div>
          ))}
        </div>
      </section>

      {/* Scrollytelling product tour */}
      <section id="product" className="px-5 pb-28">
        <div className="mx-auto max-w-6xl">
          <div data-reveal className="mx-auto mb-16 max-w-2xl text-center">
            <span className="text-xs font-semibold uppercase tracking-[0.2em] text-primary-light">
              Product tour
            </span>
            <h2 className="mt-3 text-3xl font-bold tracking-tight md:text-[42px] md:leading-[1.15]">
              Everything your hybrid team needs, in one place
            </h2>
          </div>

          <div className="grid gap-10 lg:grid-cols-2 lg:gap-16">
            {/* Steps */}
            <div className="order-2 lg:order-1">
              {showcaseSteps.map((step, i) => {
                const Icon = step.icon;
                const active = activeStep === i;
                return (
                  <div
                    key={step.id}
                    data-step
                    className="flex min-h-[46vh] flex-col justify-center py-10 lg:min-h-[62vh]"
                  >
                    <div
                      className={cn(
                        "rounded-xl border p-7 transition-all duration-500",
                        active
                          ? "border-primary/30 bg-surface shadow-glow"
                          : "border-transparent opacity-45",
                      )}
                    >
                      <span
                        className={cn(
                          "mb-4 inline-flex h-11 w-11 items-center justify-center rounded-md transition-colors duration-500",
                          active ? "bg-primary text-white" : "bg-surface-overlay text-text-muted",
                        )}
                      >
                        <Icon size={20} />
                      </span>
                      <p className="text-xs font-semibold uppercase tracking-[0.18em] text-primary-light">
                        {step.kicker}
                      </p>
                      <h3 className="mt-2 text-2xl font-bold tracking-tight">{step.title}</h3>
                      <p className="mt-3 text-sm leading-relaxed text-text-secondary">
                        {step.description}
                      </p>
                    </div>

                    {/* Inline screenshot on small screens */}
                    <div className="mt-6 overflow-hidden rounded-xl border border-border shadow-md lg:hidden">
                      <img src={step.image} alt={step.title} className="w-full" loading="lazy" />
                    </div>
                  </div>
                );
              })}
            </div>

            {/* Sticky screenshot on large screens */}
            <div className="order-1 hidden lg:order-2 lg:block">
              <div className="sticky top-28 h-[calc(100vh-180px)]">
                <div className="relative h-full">
                  <div className="absolute -inset-4 rounded-2xl bg-primary/10 blur-2xl" aria-hidden />
                  {showcaseSteps.map((step, i) => (
                    <div
                      key={step.id}
                      className={cn(
                        "absolute inset-0 flex items-center transition-all duration-700 ease-out",
                        activeStep === i
                          ? "z-10 translate-y-0 opacity-100"
                          : "z-0 translate-y-3 opacity-0",
                      )}
                    >
                      <img
                        src={step.image}
                        alt={step.title}
                        loading="lazy"
                        className="w-full rounded-xl border border-border-strong/60 shadow-lg"
                      />
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Feature grid */}
      <section id="features" className="border-t border-border/50 bg-bg px-5 py-24">
        <div className="mx-auto max-w-6xl">
          <div data-reveal className="mx-auto mb-14 max-w-2xl text-center">
            <span className="text-xs font-semibold uppercase tracking-[0.2em] text-primary-light">
              Built for scale
            </span>
            <h2 className="mt-3 text-3xl font-bold tracking-tight md:text-[42px] md:leading-[1.15]">
              A serious platform with a playful heart
            </h2>
          </div>

          <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
            {featureCards.map((feature) => {
              const Icon = feature.icon;
              return (
                <div
                  key={feature.title}
                  data-reveal
                  className="group rounded-xl border border-border bg-surface p-6 transition-all duration-300 hover:-translate-y-1 hover:border-primary/30 hover:shadow-glow"
                >
                  <span className="mb-4 inline-flex h-11 w-11 items-center justify-center rounded-md bg-primary-muted text-primary-light transition-transform duration-300 group-hover:scale-110">
                    <Icon size={20} />
                  </span>
                  <h3 className="text-base font-semibold">{feature.title}</h3>
                  <p className="mt-2 text-sm leading-relaxed text-text-secondary">
                    {feature.description}
                  </p>
                </div>
              );
            })}
          </div>
        </div>
      </section>

      {/* Quote */}
      <section className="px-5 py-24">
        <figure data-reveal className="mx-auto max-w-3xl text-center">
          <blockquote className="text-2xl font-medium leading-relaxed tracking-tight text-text md:text-3xl">
            "We onboarded three AI agents in an afternoon. They now handle research, first drafts
            and QA while the team focuses on decisions. It feels like the office grew overnight."
          </blockquote>
          <figcaption className="mt-6 text-sm text-text-muted">
            <span className="font-semibold text-text-secondary">Tom Jami</span>, Founder at Yapio
          </figcaption>
        </figure>
      </section>

      {/* Final CTA */}
      <section className="px-5 pb-28">
        <div
          data-reveal
          className="relative mx-auto max-w-5xl overflow-hidden rounded-2xl border border-primary/25 px-8 py-16 text-center md:py-20"
          style={{ background: "linear-gradient(160deg, #17122e 0%, #12121a 55%, #0e0e16 100%)" }}
        >
          <div
            className="pointer-events-none absolute -top-32 left-1/2 h-72 w-[560px] -translate-x-1/2 rounded-full bg-primary/25 blur-[100px]"
            aria-hidden
          />
          <img
            src="/branding/logo-without-bg.png"
            alt=""
            aria-hidden
            className="mx-auto mb-6 h-14 w-14 object-contain"
          />
          <h2 className="relative text-3xl font-bold tracking-tight md:text-[44px] md:leading-[1.1]">
            Ready to meet your new teammates?
          </h2>
          <p className="relative mx-auto mt-4 max-w-md text-sm text-text-secondary md:text-base">
            Spin up your workspace, invite your team and hire your first AI agent today.
          </p>
          <div className="relative mt-8 flex justify-center">
            <Link to="/login">
              <Button size="lg" className="px-8 shadow-glow-strong">
                Get started now <ArrowRight size={16} />
              </Button>
            </Link>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="border-t border-border/50 bg-bg-deep px-5 py-10">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 md:flex-row">
          <LandingLogo />
          <p className="text-xs text-text-muted">
            The workspace for AI and human employees. Built with care.
          </p>
          <div className="flex items-center gap-5 text-xs text-text-muted">
            <a href="#product" className="transition-colors hover:text-text">
              Product
            </a>
            <a href="#features" className="transition-colors hover:text-text">
              Features
            </a>
            <Link to="/login" className="transition-colors hover:text-text">
              Sign in
            </Link>
          </div>
        </div>
      </footer>
    </div>
  );
}
