import { lazy, Suspense, useEffect, useLayoutEffect, useRef, useState } from "react";
import { Link } from "@tanstack/react-router";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { ArrowRight, Menu, X } from "lucide-react";
import { HeroScene } from "@/components/landing/hero-scene";
import { FinalCta } from "@/components/landing/final-cta";
import { LazyWhenVisible } from "@/components/landing/lazy-when-visible";
import { SiteFooter } from "@/components/landing/site-footer";
import { WhyMokaid } from "@/components/landing/why-mokaid";
import { RandomLetterSwap } from "@/components/ui/random-letter-swap";
import { cn } from "@/lib/cn";
import { useSmoothScroll } from "@/lib/use-smooth-scroll";
import { useAuthStore } from "@/stores/auth-store";
import { Button } from "@/components/ui/button";

gsap.registerPlugin(ScrollTrigger);

const HireOverlay = lazy(() =>
  import("@/components/landing/hire-overlay").then((m) => ({ default: m.HireOverlay })),
);
const OfficeTour = lazy(() =>
  import("@/components/landing/office-tour").then((m) => ({ default: m.OfficeTour })),
);
const AgentTour = lazy(() =>
  import("@/components/landing/agent-tour").then((m) => ({ default: m.AgentTour })),
);
const McpConnectors = lazy(() =>
  import("@/components/landing/mcp-connectors").then((m) => ({ default: m.McpConnectors })),
);

const marqueeItems = ["Agents", "Office", "Connectors", "Knowledge", "Tasks"];

const navLinks = [
  { href: "#product", label: "Product" },
  { href: "#agents", label: "Agents" },
  { href: "#connectors", label: "Connectors" },
  { href: "#why", label: "Why mokaid" },
] as const;

function LandingLogo() {
  return (
    <span className="flex items-center gap-2.5 sm:gap-3">
      <span className="relative flex h-9 w-9 items-center justify-center rounded-xl border border-primary/20 bg-primary/10 sm:h-10 sm:w-10">
        <picture>
          <source srcSet="/branding/logo-without-bg.webp" type="image/webp" />
          <img
            src="/branding/logo-without-bg.png"
            alt="mokaid"
            className="h-6 w-6 object-contain sm:h-7 sm:w-7"
            width={28}
            height={28}
            decoding="async"
          />
        </picture>
      </span>
      <span className="mk-brand-wordmark text-[15px] tracking-tight text-text sm:text-[17px]">
        mokaid
      </span>
    </span>
  );
}

function SectionFallback({ className }: { className?: string }) {
  return <div className={cn("bg-bg-deep", className)} aria-hidden />;
}

function NavLink({
  href,
  label,
  className,
  onClick,
  letterSwap = false,
}: {
  href: string;
  label: string;
  className?: string;
  onClick?: () => void;
  letterSwap?: boolean;
}) {
  return (
    <a
      href={href}
      onClick={onClick}
      className={cn(
        "mk-focus-ring rounded-md transition-colors",
        className,
      )}
    >
      {letterSwap ? (
        <RandomLetterSwap
          label={label}
          staggerDuration={0.025}
          transition={{ duration: 0.55, type: "spring", bounce: 0 }}
          className="text-[13px] font-medium text-text-secondary hover:text-text"
        />
      ) : (
        label
      )}
    </a>
  );
}

export function LandingPage() {
  useSmoothScroll();

  const rootRef = useRef<HTMLDivElement>(null);
  const introRef = useRef<HTMLElement>(null);
  const [headerScrolled, setHeaderScrolled] = useState(false);
  const [headerVisible, setHeaderVisible] = useState(false);
  const [hireVisible, setHireVisible] = useState(true);
  const [menuOpen, setMenuOpen] = useState(false);
  const token = useAuthStore((s) => s.token);

  useEffect(() => {
    // The landing page owns the scroll; the app shell uses inner scrolling.
    document.documentElement.style.overflowY = "auto";
    document.documentElement.style.overflowX = "clip";
    return () => {
      document.documentElement.style.overflowY = "";
      document.documentElement.style.overflowX = "";
    };
  }, []);

  useEffect(() => {
    if (!headerVisible) setMenuOpen(false);
  }, [headerVisible]);

  useEffect(() => {
    if (!menuOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setMenuOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [menuOpen]);

  useEffect(() => {
    let raf = 0;
    const onScroll = () => {
      if (raf) return;
      raf = window.requestAnimationFrame(() => {
        raf = 0;
        const threshold = window.innerHeight * 0.55;
        const nextScrolled = window.scrollY > threshold;
        setHeaderScrolled((prev) => (prev === nextScrolled ? prev : nextScrolled));

        // Hire line: hero only on mobile; on desktop hide once past mid-page so it does not
        // cover stats / CTA / footer (was stuck visible for the whole scroll).
        const isDesktop = window.matchMedia("(min-width: 768px)").matches;
        const introBottom = introRef.current?.offsetHeight ?? window.innerHeight * 1.8;
        const maxY = document.documentElement.scrollHeight - window.innerHeight;
        const beforeFooter = window.scrollY < maxY - window.innerHeight * 0.85;
        const nextHire = isDesktop
          ? window.scrollY < introBottom * 1.35 && beforeFooter
          : window.scrollY < introBottom * 0.82;
        setHireVisible((prev) => (prev === nextHire ? prev : nextHire));
      });
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    window.addEventListener("resize", onScroll, { passive: true });
    return () => {
      window.removeEventListener("scroll", onScroll);
      window.removeEventListener("resize", onScroll);
      if (raf) window.cancelAnimationFrame(raf);
    };
  }, []);

  useLayoutEffect(() => {
    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const ctx = gsap.context(() => {
      const header = "[data-landing-header]";
      const heroScene = "[data-hero-scene]";

      if (prefersReduced) {
        gsap.set(header, { opacity: 1, y: 0 });
        gsap.set(heroScene, { opacity: 0 });
        setHeaderVisible(true);
      } else {
        gsap.set(header, { opacity: 0, y: -12 });
        gsap.set(heroScene, { opacity: 1, scale: 1, yPercent: 0 });

        gsap
          .timeline({
            defaults: { ease: "none" },
            scrollTrigger: {
              trigger: introRef.current,
              start: "top top",
              end: "bottom bottom",
              scrub: 0.65,
              onUpdate: (self) => {
                const next = self.progress > 0.2;
                setHeaderVisible((prev) => (prev === next ? prev : next));
              },
            },
          })
          .to(header, { opacity: 1, y: 0, duration: 0.25 }, 0.18)
          .to(
            heroScene,
            {
              opacity: 0,
              scale: 1.08,
              yPercent: -8,
              duration: 0.45,
            },
            0.45,
          );
      }

      gsap.utils.toArray<HTMLElement>("[data-reveal]").forEach((el) => {
        gsap.from(el, {
          y: 28,
          opacity: 0,
          duration: 0.7,
          ease: "power3.out",
          scrollTrigger: { trigger: el, start: "top 86%" },
        });
      });

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
    }, rootRef);

    return () => ctx.revert();
  }, []);

  return (
    <div ref={rootRef} className="mk-landing min-h-full overflow-x-clip bg-bg-deep text-text">
      <Suspense fallback={null}>
        <HireOverlay visible={hireVisible} />
      </Suspense>

      <header
        data-landing-header
        className={cn(
          "fixed inset-x-0 top-0 z-50 border-b pt-[env(safe-area-inset-top)] transition-[background-color,backdrop-filter,box-shadow,border-color] duration-300",
          headerVisible ? "pointer-events-auto" : "pointer-events-none",
          headerScrolled || menuOpen
            ? "mk-header-scrolled border-primary/15 shadow-[0_8px_32px_rgba(0,0,0,0.35)]"
            : "border-transparent bg-transparent backdrop-blur-none",
        )}
      >
        <div className="mx-auto grid h-14 max-w-7xl grid-cols-[1fr_auto] items-center gap-3 px-4 sm:h-16 sm:grid-cols-[1fr_auto_1fr] sm:px-6 lg:px-10">
          <Link to="/" className="mk-focus-ring w-fit rounded-xl">
            <LandingLogo />
          </Link>

          <nav
            className="hidden items-center justify-center gap-1 md:flex"
            aria-label="Primary"
          >
            {navLinks.map((link) => (
              <NavLink
                key={link.href}
                href={link.href}
                label={link.label}
                letterSwap
                className="px-3.5 py-2"
              />
            ))}
          </nav>

          <div className="flex items-center justify-end gap-1.5 sm:gap-2.5">
            {token ? (
              <Link to="/dashboard">
                <Button size="sm" className="min-h-9 px-3.5 sm:min-h-9">
                  Open app <ArrowRight size={14} />
                </Button>
              </Link>
            ) : (
              <>
                <Link to="/login" className="hidden min-[400px]:block">
                  <Button
                    variant="ghost"
                    size="sm"
                    className="min-h-9 text-text-secondary hover:text-text sm:min-h-9"
                  >
                    Sign in
                  </Button>
                </Link>
                <Link to="/signup">
                  <Button size="sm" className="min-h-9 px-3.5 shadow-glow sm:min-h-9 sm:px-4">
                    <span className="sm:hidden">Start</span>
                    <span className="hidden sm:inline">Get started</span>
                    <ArrowRight size={14} />
                  </Button>
                </Link>
              </>
            )}

            <button
              type="button"
              className="mk-focus-ring inline-flex h-9 w-9 items-center justify-center rounded-lg border border-transparent text-text-secondary transition-colors hover:border-white/10 hover:bg-surface/50 hover:text-text md:hidden"
              aria-expanded={menuOpen}
              aria-controls="landing-mobile-nav"
              aria-label={menuOpen ? "Close menu" : "Open menu"}
              onClick={() => setMenuOpen((v) => !v)}
            >
              {menuOpen ? <X size={18} /> : <Menu size={18} />}
            </button>
          </div>
        </div>

        <div
          id="landing-mobile-nav"
          className={cn(
            "border-t border-primary/10 bg-bg-deep/90 backdrop-blur-xl md:hidden",
            menuOpen ? "block" : "hidden",
          )}
        >
          <nav className="mx-auto flex max-w-7xl flex-col gap-0.5 px-4 py-3 sm:px-6" aria-label="Mobile">
            {navLinks.map((link) => (
              <NavLink
                key={link.href}
                href={link.href}
                label={link.label}
                className="rounded-lg px-3 py-3 text-[15px] font-medium text-text-secondary transition-colors hover:bg-surface/40 hover:text-text"
                onClick={() => setMenuOpen(false)}
              />
            ))}
            {!token && (
              <Link
                to="/login"
                className="rounded-lg px-3 py-3 text-[15px] font-medium text-text-secondary transition-colors hover:bg-surface/40 hover:text-text min-[400px]:hidden"
                onClick={() => setMenuOpen(false)}
              >
                Sign in
              </Link>
            )}
          </nav>
        </div>
      </header>

      <section ref={introRef} className="relative h-[165vh] sm:h-[180vh]">
        <div className="sticky top-0 h-svh overflow-hidden bg-bg-deep">
          <HeroScene />
        </div>
      </section>

      <LazyWhenVisible placeholderClassName="mk-landing-ph-office" rootMargin="400px 0px">
        <Suspense fallback={<SectionFallback className="mk-landing-ph-office" />}>
          <OfficeTour />
        </Suspense>
      </LazyWhenVisible>

      <section className="mk-signal-rail relative isolate overflow-hidden py-5" aria-hidden>
        <div className="mk-signal-rail__fade">
          <div className="mk-marquee flex w-max items-center gap-8 sm:gap-12">
            {[...marqueeItems, ...marqueeItems, ...marqueeItems, ...marqueeItems].map((item, i) => (
              <span key={i} className="mk-signal-chip__label">
                {item}
              </span>
            ))}
          </div>
        </div>
      </section>

      <WhyMokaid />

      <LazyWhenVisible placeholderClassName="mk-landing-ph-agent" rootMargin="320px 0px">
        <Suspense fallback={<SectionFallback className="mk-landing-ph-agent" />}>
          <AgentTour />
        </Suspense>
      </LazyWhenVisible>

      <LazyWhenVisible minHeight="80vh" rootMargin="200px 0px">
        <Suspense fallback={<SectionFallback className="min-h-[80vh]" />}>
          <McpConnectors />
        </Suspense>
      </LazyWhenVisible>

      <section className="px-4 py-16 sm:px-5 sm:py-24">
        <figure data-reveal className="mx-auto max-w-3xl text-center">
          <blockquote className="text-xl font-medium leading-relaxed tracking-tight text-text sm:text-2xl md:text-3xl">
            "We onboarded three AI agents in an afternoon. They now handle research, first drafts
            and QA while the team focuses on decisions. It feels like the office grew overnight."
          </blockquote>
          <figcaption className="mt-6 text-sm text-text-muted">
            <span className="font-semibold text-text-secondary">Tom Jami</span>, Founder at Yapio
          </figcaption>
        </figure>
      </section>

      <FinalCta />
      <SiteFooter />
    </div>
  );
}
