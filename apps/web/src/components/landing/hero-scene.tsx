import { useLayoutEffect, useRef, type CSSProperties } from "react";
import gsap from "gsap";
import { Link } from "@tanstack/react-router";
import {
  ArrowDown,
  Download,
  ArrowRight,
  BarChart3,
  ClipboardCheck,
  ShieldCheck,
  User,
} from "lucide-react";

const features = [
  { icon: User, label: "AI Employees" },
  { icon: ClipboardCheck, label: "Smart Tasks" },
  { icon: BarChart3, label: "Real Performance" },
  { icon: ShieldCheck, label: "Secure & Reliable" },
] as const;

export function HeroScene() {
  const rootRef = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root) return;

    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (prefersReduced) return;

    const ctx = gsap.context(() => {
      gsap.set(
        [
          "[data-hero-wordmark]",
          "[data-hero-tagline]",
          "[data-hero-sub]",
          "[data-hero-features] .mk-hero-feature-item",
          "[data-hero-scroll]",
        ],
        { opacity: 0, y: 20 },
      );
      gsap.set("[data-hero-bloom]", { opacity: 0, scale: 0.85 });

      gsap
        .timeline({ defaults: { ease: "power3.out" } })
        .to("[data-hero-bloom]", { opacity: 1, scale: 1, duration: 1.4 }, 0)
        .to("[data-hero-wordmark]", { opacity: 1, y: 0, duration: 0.85 }, 0.25)
        .to("[data-hero-tagline]", { opacity: 1, y: 0, duration: 0.65 }, 0.55)
        .to("[data-hero-sub]", { opacity: 1, y: 0, duration: 0.6 }, 0.7)
        .to(
          "[data-hero-features] .mk-hero-feature-item",
          { opacity: 1, y: 0, duration: 0.5, stagger: 0.08 },
          0.85,
        )
        .to("[data-hero-scroll]", { opacity: 1, y: 0, duration: 0.45 }, 1.1);
    }, root);

    return () => ctx.revert();
  }, []);

  return (
    <div ref={rootRef} data-hero-scene className="mk-hero absolute inset-0">
      <div className="mk-hero-bg" aria-hidden />
      <div data-hero-bloom className="mk-hero-bloom" aria-hidden />

      <div className="mk-hero-content">
        <div data-hero-wordmark className="mk-hero-brand">
          <span className="mk-hero-wordmark-back" aria-hidden>
            mokaid
          </span>
          <h1 className="mk-hero-wordmark">mokaid</h1>
        </div>

        <p data-hero-tagline className="mk-hero-tagline">
          <span className="mk-hero-tagline-white">AI Employees.</span>{" "}
          <span className="mk-hero-tagline-purple">Real Results.</span>
        </p>

        <p data-hero-sub className="mk-hero-sub">
          Your AI team, together in one desktop app. Assign tasks, follow their work and make the
          decisions that matter.
        </p>

        <div className="mt-6 flex flex-wrap items-center justify-center gap-3">
          <Link
            to="/download"
            className="mk-focus-ring inline-flex min-h-12 items-center gap-2 rounded-lg bg-primary px-6 text-sm font-semibold text-white transition-colors hover:bg-primary-dark"
          >
            <Download size={18} aria-hidden /> Download Mokaid
          </Link>
          <Link
            to="/account"
            className="mk-focus-ring inline-flex min-h-12 items-center gap-2 rounded-lg border border-white/20 px-6 text-sm font-medium text-text transition-colors hover:bg-white/5"
          >
            My account <ArrowRight size={16} aria-hidden />
          </Link>
        </div>
        <p className="mt-3 max-w-md text-xs leading-relaxed text-text-secondary">
          macOS &amp; Windows · Usage, plans and billing on the web.
        </p>

        <div data-hero-features className="mk-hero-features-wrap">
          <ul className="mk-hero-features">
            {features.map(({ icon: Icon, label }, i) => (
              <li key={label} className="mk-hero-feature">
                {i > 0 ? <span className="mk-hero-feature-sep" aria-hidden /> : null}
                <span
                  className="mk-hero-feature-item"
                  style={{ "--neon-delay": `${i * 0.55}s` } as CSSProperties}
                >
                  <span className="mk-hero-feature-box">
                    <span className="mk-hero-feature-neon" aria-hidden />
                    <Icon size={20} strokeWidth={1.4} aria-hidden />
                  </span>
                  <span className="mk-hero-feature-label">{label}</span>
                </span>
              </li>
            ))}
          </ul>
        </div>

        <div data-hero-scroll className="mk-hero-scroll">
          <span className="mk-hero-scroll-text">Scroll</span>
          <ArrowDown size={11} strokeWidth={1.75} aria-hidden />
          <span className="mk-hero-scroll-pill" aria-hidden>
            <span className="mk-hero-scroll-dot" />
          </span>
        </div>
      </div>
    </div>
  );
}
