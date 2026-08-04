import { useLayoutEffect, useRef } from "react";
import { Link } from "@tanstack/react-router";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";

gsap.registerPlugin(ScrollTrigger);

/** Minimal final CTA — soft glass, one smooth entrance, no looping ornament. */
export function FinalCta() {
  const rootRef = useRef<HTMLElement>(null);

  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root) return;

    const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const ctx = gsap.context(() => {
      if (prefersReduced) {
        gsap.set("[data-cta-panel]", { opacity: 1, y: 0 });
        return;
      }

      gsap.from("[data-cta-panel]", {
        y: 20,
        opacity: 0,
        duration: 0.7,
        ease: "power2.out",
        scrollTrigger: {
          trigger: root,
          start: "top 82%",
          once: true,
        },
      });
    }, root);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={rootRef} className="mk-final-cta relative isolate">
      <div className="mk-final-cta-glow pointer-events-none absolute inset-0" aria-hidden />

      <div className="relative mx-auto max-w-5xl px-4 py-14 sm:px-6 sm:py-16 md:py-20">
        <div
          data-cta-panel
          className="mk-final-cta-panel grid items-center gap-8 p-7 sm:gap-10 sm:p-10 md:grid-cols-12 md:p-12"
        >
          <div className="md:col-span-7 lg:col-span-8">
            <picture>
              <source srcSet="/branding/logo-without-bg.webp" type="image/webp" />
              <img
                src="/branding/logo-without-bg.png"
                alt=""
                aria-hidden
                width={40}
                height={40}
                decoding="async"
                loading="lazy"
                className="mb-5 h-10 w-10 object-contain opacity-90"
              />
            </picture>

            <h2 className="max-w-xl text-[1.65rem] font-bold leading-[1.12] tracking-tight text-text sm:text-3xl md:text-[2.4rem] md:leading-[1.1]">
              Ready to meet your{" "}
              <span className="text-primary-light">new teammates</span>?
            </h2>

            <p className="mt-3.5 max-w-md text-sm leading-relaxed text-text-secondary md:text-[15px]">
              Spin up your workspace, invite your team and hire your first AI agent today.
            </p>
          </div>

          <div className="flex flex-col items-stretch gap-3 md:col-span-5 md:items-end lg:col-span-4">
            <p className="text-[12px] text-text-muted md:text-right">
              First agent in about{" "}
              <span className="font-medium text-primary-light">3 min</span>
            </p>

            <Link to="/signup" className="block w-full md:inline-block md:w-auto">
              <Button size="lg" className="w-full px-8 shadow-glow md:w-auto">
                Get started now <ArrowRight size={16} />
              </Button>
            </Link>

            <p className="text-center text-[11px] text-text-muted md:text-right">
              Free workspace · No card required
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
