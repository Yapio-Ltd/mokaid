import { useEffect } from "react";
import gsap from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import Lenis from "lenis";
import "lenis/dist/lenis.css";

gsap.registerPlugin(ScrollTrigger);

/**
 * Lenis smooth scrolling wired into the GSAP ticker so ScrollTrigger
 * and Lenis share a single rAF loop (desktop). Mobile keeps native scroll.
 */
export function useSmoothScroll() {
  useEffect(() => {
    const desktop = window.matchMedia("(min-width: 768px)");
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    const coarsePointer = window.matchMedia("(pointer: coarse)");
    const noHover = window.matchMedia("(hover: none)");
    const mediaQueries = [desktop, reducedMotion, coarsePointer, noHover];
    let lenis: Lenis | null = null;
    let resizeTimer = 0;
    const tick = (time: number) => {
      lenis?.raf(time * 1000);
    };
    const resizeLenis = () => lenis?.resize();
    const configureScroll = () => {
      // A media change and React StrictMode must never leave two scroll owners.
      gsap.ticker.remove(tick);
      lenis?.destroy();
      lenis = null;
      const native =
        !desktop.matches ||
        reducedMotion.matches ||
        coarsePointer.matches ||
        (navigator.maxTouchPoints > 0 && noHover.matches);
      if (native) return;

      lenis = new Lenis({
        autoRaf: false,
        duration: 0.65,
        easing: (t) => 1 - Math.pow(1 - t, 3),
        wheelMultiplier: 1.05,
        smoothWheel: true,
        // Lenis already honors the target's CSS scroll-margin-top.
        anchors: true,
      });
      lenis.on("scroll", ScrollTrigger.update);
      gsap.ticker.add(tick);
      gsap.ticker.lagSmoothing(0);
    };

    const onResize = () => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        resizeLenis();
        ScrollTrigger.refresh();
      }, 160);
    };
    const onMediaChange = () => {
      configureScroll();
      onResize();
    };

    configureScroll();
    ScrollTrigger.addEventListener("refresh", resizeLenis);
    mediaQueries.forEach((query) => query.addEventListener("change", onMediaChange));
    window.addEventListener("resize", onResize);
    window.visualViewport?.addEventListener("resize", onResize);

    // Initial measure after first paint; cancel it if StrictMode remounts us.
    const initialFrame = requestAnimationFrame(() => {
      resizeLenis();
      ScrollTrigger.refresh();
    });

    return () => {
      cancelAnimationFrame(initialFrame);
      window.clearTimeout(resizeTimer);
      window.removeEventListener("resize", onResize);
      window.visualViewport?.removeEventListener("resize", onResize);
      mediaQueries.forEach((query) => query.removeEventListener("change", onMediaChange));
      ScrollTrigger.removeEventListener("refresh", resizeLenis);
      gsap.ticker.remove(tick);
      lenis?.destroy();
    };
  }, []);
}
