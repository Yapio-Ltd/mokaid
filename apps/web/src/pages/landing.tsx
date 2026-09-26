import { useEffect, useLayoutEffect, useRef } from "react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { HeroScene } from "@/components/landing/hero-scene";
import { CinematicStory } from "@/components/landing/cinematic-story";
import { SiteFooter } from "@/components/landing/site-footer";
import { SiteHeader } from "@/components/landing/site-header";
import { ORGANIZATION_JSONLD, SITE, SOFTWARE_JSONLD } from "@/lib/seo";
import { useSeo } from "@/lib/use-seo";
import { useSmoothScroll } from "@/lib/use-smooth-scroll";

gsap.registerPlugin(ScrollTrigger);

export function LandingPage() {
  useSeo({
    title: SITE.defaultTitle,
    description: SITE.defaultDescription,
    path: "/",
    jsonLd: [
      SOFTWARE_JSONLD,
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "@id": `${SITE.url}/#website`,
        name: SITE.name,
        url: SITE.url,
        publisher: ORGANIZATION_JSONLD["@id"] ? { "@id": ORGANIZATION_JSONLD["@id"] } : undefined,
      },
    ],
  });
  useSmoothScroll();

  const rootRef = useRef<HTMLDivElement>(null);
  const introRef = useRef<HTMLElement>(null);

  useEffect(() => {
    // The landing page owns the scroll; the app shell uses inner scrolling.
    document.documentElement.style.overflowY = "auto";
    document.documentElement.style.overflowX = "clip";
    return () => {
      document.documentElement.style.overflowY = "";
      document.documentElement.style.overflowX = "";
    };
  }, []);

  useLayoutEffect(() => {
    const media = gsap.matchMedia();
    media.add(
      {
        desktop: "(min-width: 768px)",
        reducedMotion: "(prefers-reduced-motion: reduce)",
      },
      (context) => {
        const heroScene = "[data-hero-scene]";
        gsap.set(heroScene, { opacity: 1, scale: 1, yPercent: 0 });
        if (!context.conditions?.desktop || context.conditions?.reducedMotion) return;

        gsap
          .timeline({
            defaults: { ease: "none" },
            scrollTrigger: {
              trigger: introRef.current,
              start: "top top",
              end: "bottom bottom",
              scrub: 0.65,
            },
          })
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
      },
      rootRef,
    );

    return () => media.revert();
  }, []);

  return (
    <div ref={rootRef} className="mk-landing min-h-full overflow-x-clip bg-bg-deep text-text">
      <SiteHeader overlayHero />

      <section ref={introRef} className="relative md:h-[180vh] motion-reduce:!h-auto">
        <div className="relative min-h-svh overflow-hidden bg-bg-deep md:sticky md:top-0 md:h-svh motion-reduce:!relative motion-reduce:!h-auto max-md:[&_.mk-hero]:!relative max-md:[&_.mk-hero-content]:min-h-svh motion-reduce:[&_.mk-hero]:!relative motion-reduce:[&_.mk-hero-content]:min-h-svh">
          <HeroScene />
        </div>
      </section>

      <CinematicStory />
      <SiteFooter compact />
    </div>
  );
}
