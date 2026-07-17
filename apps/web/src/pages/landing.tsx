import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { Link } from "@tanstack/react-router";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import {
  ArrowRight,
  BarChart3,
  Bot,
  Calendar,
  CheckCircle2,
  CheckSquare,
  CreditCard,
  FolderKanban,
  FolderOpen,
  LayoutDashboard,
  Library,
  Plug,
  Settings,
  Users,
} from "lucide-react";
import UnicornScene from "unicornstudio-react";
import { cn } from "@/lib/cn";
import { useSmoothScroll } from "@/lib/use-smooth-scroll";
import { useAuthStore } from "@/stores/auth-store";
import { Button } from "@/components/ui/button";

gsap.registerPlugin(ScrollTrigger);

const showcaseSteps = [
  {
    id: "dashboard",
    image: "/images/dashboard.png",
    icon: LayoutDashboard,
    kicker: "Live workspace",
    title: "See your whole team at a glance",
    description:
      "A real time 3D office where every AI and human agent is visible, with status, current task and performance. Click anyone to open their full profile.",
  },
  {
    id: "agents",
    image: "/images/agents.png",
    icon: Bot,
    kicker: "Agent management",
    title: "Hire, brief and grow your agents",
    description:
      "AI agents, human linked agents and hybrids live side by side. Skills, levels, teams and performance tracking, all in one clean directory.",
  },
  {
    id: "tasks",
    image: "/images/tasks.png",
    icon: CheckSquare,
    kicker: "Task orchestration",
    title: "Work flows through a living board",
    description:
      "Kanban, list and timeline views with live progress from every agent. Assign work to an AI the same way you assign it to a person.",
  },
  {
    id: "projects",
    image: "/images/projects.png",
    icon: FolderKanban,
    kicker: "Project management",
    title: "Organize work by initiative",
    description:
      "Track milestones, owners and progress across every project. See activity, deadlines and agent assignments in one focused view.",
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
    id: "settings",
    image: "/images/workspace%20settings.png",
    icon: Settings,
    kicker: "Workspace settings",
    title: "Tune the platform to your team",
    description:
      "Branding, feature toggles, approval flows and workspace preferences. Configure how your hybrid workforce operates from day one.",
  },
  {
    id: "members",
    image: "/images/members.png",
    icon: Users,
    kicker: "Team management",
    title: "Invite humans and assign roles",
    description:
      "Owners, admins and members with clear permissions. Grow your workspace and keep every teammate, human or AI, in the right place.",
  },
  {
    id: "integrations",
    image: "/images/integrations.png",
    icon: Plug,
    kicker: "Integrations",
    title: "Plugs into your stack",
    description:
      "Slack, GitHub, Notion, Figma and more. Connect the tools your team already uses and let agents work where work already lives.",
  },
  {
    id: "billing",
    image: "/images/billing.png",
    icon: CreditCard,
    kicker: "Billing",
    title: "Usage based, fully transparent",
    description:
      "Track AI requests, automations and storage in real time. Clear plans, detailed invoices and no billing surprises.",
  },
];

const featureGroups = [
  {
    label: "Work",
    features: [
      {
        icon: LayoutDashboard,
        title: "Dashboard",
        description: "Live 3D office with every agent visible.",
      },
      {
        icon: Bot,
        title: "Agents",
        description: "Hire and manage AI and human agents.",
      },
      {
        icon: CheckSquare,
        title: "Tasks",
        description: "Kanban, list and timeline with live progress.",
      },
      {
        icon: FolderKanban,
        title: "Projects",
        description: "Milestones, owners and activity in one view.",
      },
      {
        icon: Library,
        title: "Knowledge",
        description: "Docs and briefs your agents actually read.",
      },
      {
        icon: FolderOpen,
        title: "Drive",
        description: "Files, folders and shared workspace storage.",
      },
      {
        icon: Calendar,
        title: "Calendar",
        description: "Deadlines, meetings and time off.",
      },
      {
        icon: BarChart3,
        title: "Analytics",
        description: "Throughput and performance over time.",
      },
    ],
  },
  {
    label: "Workspace",
    features: [
      {
        icon: Settings,
        title: "Settings",
        description: "Branding, toggles and approval flows.",
      },
      {
        icon: Users,
        title: "Members",
        description: "Roles and permissions for your team.",
      },
      {
        icon: Plug,
        title: "Integrations",
        description: "Slack, GitHub, Notion, Figma and more.",
      },
      {
        icon: CreditCard,
        title: "Billing",
        description: "Usage tracking and clear invoices.",
      },
    ],
  },
];

const marqueeItems = [
  "Dashboard",
  "Agents",
  "Tasks",
  "Projects",
  "Knowledge",
  "Drive",
  "Calendar",
  "Analytics",
  "Members",
  "Integrations",
  "Billing",
  "3D office",
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
  const [headerScrolled, setHeaderScrolled] = useState(false);
  const token = useAuthStore((s) => s.token);

  useEffect(() => {
    // The landing page owns the scroll; the app shell uses inner scrolling.
    document.documentElement.style.overflowY = "auto";
    return () => {
      document.documentElement.style.overflowY = "";
    };
  }, []);

  useEffect(() => {
    const onScroll = () => setHeaderScrolled(window.scrollY > 32);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useLayoutEffect(() => {
    const ctx = gsap.context(() => {
      // Hero entrance
      gsap
        .timeline({ defaults: { ease: "power3.out" } })
        .from("[data-hero-badge]", { y: 20, opacity: 0, duration: 0.6 })
        .from(
          "[data-hero-wordmark]",
          { y: 12, opacity: 0, scale: 0.92, duration: 0.7, ease: "back.out(1.4)" },
          "-=0.35",
        )
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
      {/* Hero */}
      <section className="relative overflow-hidden px-5 pb-24 pt-28 md:pt-32">
        {/* Nav — transparent overlay, glass on scroll */}
        <header
          className={cn(
            "fixed inset-x-0 top-0 z-50 border-b transition-[background-color,backdrop-filter,-webkit-backdrop-filter] duration-300",
            headerScrolled
              ? "mk-glass border-primary/15 shadow-md backdrop-blur-xl"
              : "border-transparent bg-transparent backdrop-blur-none",
          )}
        >
          <div className="mx-auto grid h-[4.5rem] max-w-7xl grid-cols-[1fr_auto_1fr] items-center px-6 lg:px-10">
            <Link to="/" className="mk-focus-ring w-fit rounded-md">
              <LandingLogo />
            </Link>
            <nav className="hidden items-center justify-center gap-8 text-[13px] font-medium text-text-secondary md:flex">
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
            <div className="flex items-center justify-end gap-2.5">
              {token ? (
                <Link to="/dashboard">
                  <Button size="sm">
                    Open app <ArrowRight size={14} />
                  </Button>
                </Link>
              ) : (
                <>
                  <Link to="/login">
                    <Button variant="ghost" size="sm" className="text-text-secondary hover:text-text">
                      Sign in
                    </Button>
                  </Link>
                  <Link to="/signup">
                    <Button size="sm">
                      Get started <ArrowRight size={14} />
                    </Button>
                  </Link>
                </>
              )}
            </div>
          </div>
        </header>

        {/* Unicorn Studio interactive scene as hero background */}
        <div className="pointer-events-none absolute inset-0" aria-hidden>
          <UnicornScene
            projectId="AqbBSp10zZBUTiJZy0Ko"
            width="100%"
            height="100%"
            scale={1}
            dpi={1.5}
            production
            lazyLoad={false}
            ariaLabel=""
            className="h-full w-full"
          />
          <div className="absolute inset-0 bg-gradient-to-b from-bg-deep/40 via-transparent to-bg-deep" />
        </div>

        <div className="relative mx-auto max-w-4xl text-center">
          <div data-hero-badge className="flex flex-col items-center gap-4">
            <img
              src="/branding/logo-without-bg.png"
              alt=""
              aria-hidden
              className="h-20 w-20 object-contain md:h-24 md:w-24"
            />
            <p
              data-hero-wordmark
              className="mk-brand-wordmark text-[2.75rem] md:text-[3.75rem]"
              aria-label="mokaid"
            >
              <span className="mk-brand-wordmark-mok">mok</span>
              <span className="mk-brand-wordmark-aid">aid</span>
            </p>
          </div>

          <h1 className="mt-8 text-5xl font-bold leading-[1.06] tracking-tight md:mt-10 md:text-[68px]">
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
              <Link to="/signup">
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
          <div className="relative overflow-hidden rounded-2xl border border-primary/30 shadow-glow">
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
              <span className="block text-xs font-semibold">9 agents online</span>
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
      <section id="product" className="px-5 pb-28 lg:px-8">
        <div className="mx-auto max-w-[1380px]">
          <div data-reveal className="mx-auto mb-16 max-w-3xl text-center">
            <span className="text-xs font-semibold uppercase tracking-[0.2em] text-primary-light">
              Product tour
            </span>
            <h2 className="mt-3 text-3xl font-bold tracking-tight md:text-[42px] md:leading-[1.15]">
              Everything your hybrid team needs, in one place
            </h2>
          </div>

          <div className="grid gap-10 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.15fr)] lg:gap-12 xl:gap-14">
            {/* Steps */}
            <div className="order-2 lg:order-1">
              {showcaseSteps.map((step, i) => {
                const Icon = step.icon;
                const active = activeStep === i;
                return (
                  <div
                    key={step.id}
                    data-step
                    className="flex min-h-[46vh] flex-col justify-center py-10 lg:min-h-[58vh] lg:py-12"
                  >
                    <div
                      className={cn(
                        "rounded-2xl border p-8 transition-all duration-500 lg:p-10",
                        active
                          ? "border-primary/35 bg-surface shadow-glow"
                          : "border-primary/12 opacity-45",
                      )}
                    >
                      <span
                        className={cn(
                          "mb-5 inline-flex h-12 w-12 items-center justify-center rounded-lg transition-colors duration-500 lg:h-14 lg:w-14",
                          active ? "bg-primary text-white" : "bg-surface-overlay text-text-muted",
                        )}
                      >
                        <Icon size={22} />
                      </span>
                      <p className="text-xs font-semibold uppercase tracking-[0.18em] text-primary-light lg:text-[13px]">
                        {step.kicker}
                      </p>
                      <h3 className="mt-2 text-2xl font-bold tracking-tight lg:text-[30px] lg:leading-tight">
                        {step.title}
                      </h3>
                      <p className="mt-3 text-sm leading-relaxed text-text-secondary lg:text-base lg:leading-7">
                        {step.description}
                      </p>
                    </div>

                    {/* Inline screenshot on small screens */}
                    <div className="mt-6 overflow-hidden rounded-2xl border border-border shadow-md lg:hidden">
                      <img src={step.image} alt={step.title} className="w-full" loading="lazy" />
                    </div>
                  </div>
                );
              })}
            </div>

            {/* Sticky screenshot on large screens */}
            <div className="order-1 hidden lg:order-2 lg:block">
              <div className="sticky top-24 h-[calc(100vh-120px)]">
                <div className="relative h-full">
                  <div className="absolute -inset-6 rounded-2xl bg-primary/12 blur-3xl" aria-hidden />
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
                        className="w-full rounded-2xl border border-primary/30 shadow-glow"
                      />
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* Feature index — mirrors the app sidebar */}
      <section id="features" className="bg-bg px-5 py-24">
        <div className="mx-auto max-w-5xl">
          <div data-reveal className="mb-14 max-w-lg">
            <span className="text-xs font-semibold uppercase tracking-[0.2em] text-primary-light">
              What&apos;s inside
            </span>
            <h2 className="mt-3 text-3xl font-bold tracking-tight md:text-[42px] md:leading-[1.12]">
              The full product, listed plainly
            </h2>
            <p className="mt-4 text-sm leading-relaxed text-text-secondary md:text-base">
              Same structure you&apos;ll find in the app: work tools on the left, workspace admin on
              the right.
            </p>
          </div>

          <div className="grid gap-14 md:grid-cols-2 md:gap-x-20">
            {featureGroups.map((group) => (
              <div key={group.label} data-reveal>
                <p className="mb-5 text-[11px] font-semibold uppercase tracking-[0.22em] text-text-muted">
                  {group.label}
                </p>
                <ul className="space-y-0.5">
                  {group.features.map((feature) => {
                    const Icon = feature.icon;
                    return (
                      <li key={feature.title}>
                        <div className="group -mx-3 flex items-start gap-3.5 rounded-lg px-3 py-3 transition-colors duration-200 hover:bg-surface/50">
                          <Icon
                            size={16}
                            strokeWidth={1.75}
                            className="mt-0.5 shrink-0 text-text-muted transition-colors duration-200 group-hover:text-primary-light"
                          />
                          <div className="min-w-0">
                            <p className="text-[15px] font-medium leading-snug text-text transition-colors duration-200 group-hover:text-primary-light">
                              {feature.title}
                            </p>
                            <p className="mt-0.5 text-[13px] leading-relaxed text-text-muted">
                              {feature.description}
                            </p>
                          </div>
                        </div>
                      </li>
                    );
                  })}
                </ul>
              </div>
            ))}
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
            <Link to="/signup">
              <Button size="lg" className="px-8 shadow-glow-strong">
                Get started now <ArrowRight size={16} />
              </Button>
            </Link>
          </div>
        </div>
      </section>

      {/* Footer */}
      <footer className="bg-bg-deep px-5 py-10 border-t border-border/30">
        <div className="mx-auto max-w-6xl space-y-6">
          <div className="flex flex-col items-center justify-between gap-4 md:flex-row">
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
          <div className="border-t border-border/20 pt-4 flex flex-col items-center justify-between gap-2 text-[11px] text-text-muted md:flex-row">
            <p>© {new Date().getFullYear()} Mokaid. Tous droits réservés.</p>
            <div className="flex items-center gap-4">
              <Link to="/privacy" className="transition-colors hover:text-text">
                Politique de confidentialité
              </Link>
              <span>·</span>
              <Link to="/terms" className="transition-colors hover:text-text">
                Conditions d'utilisation
              </Link>
            </div>
          </div>
        </div>
      </footer>
    </div>
  );
}
