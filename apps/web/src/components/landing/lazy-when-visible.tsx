import { useEffect, useRef, useState, type ReactNode } from "react";
import { cn } from "@/lib/cn";

type Props = {
  children: ReactNode;
  /** Placeholder height before the section mounts (avoids layout jump). Cleared once visible. */
  minHeight?: string | number;
  /** Extra class applied only while waiting (e.g. height-matched placeholder). */
  placeholderClassName?: string;
  /** Start loading slightly before the section enters the viewport. */
  rootMargin?: string;
  className?: string;
  /**
   * When the URL hash matches (e.g. `#marketplace`), mount immediately so
   * in-page nav anchors still resolve after hydration replaces prerender HTML.
   */
  eagerHash?: `#${string}`;
};

function hashMatches(eagerHash?: string) {
  if (!eagerHash || typeof window === "undefined") return false;
  return window.location.hash === eagerHash;
}

/**
 * Defers mounting heavy below-fold sections until near the viewport,
 * so the hero can paint without pulling Babylon / large media chunks.
 */
export function LazyWhenVisible({
  children,
  minHeight,
  placeholderClassName,
  rootMargin = "280px 0px",
  className,
  eagerHash,
}: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const [visible, setVisible] = useState(() => hashMatches(eagerHash));
  const shouldScrollRef = useRef(hashMatches(eagerHash));

  useEffect(() => {
    if (!eagerHash) return;

    const onHash = () => {
      if (!hashMatches(eagerHash)) return;
      shouldScrollRef.current = true;
      setVisible(true);
    };

    window.addEventListener("hashchange", onHash);
    onHash();
    return () => window.removeEventListener("hashchange", onHash);
  }, [eagerHash]);

  useEffect(() => {
    const el = ref.current;
    if (!el || visible) return;

    if (typeof IntersectionObserver === "undefined") {
      setVisible(true);
      return;
    }

    const io = new IntersectionObserver(
      ([entry]) => {
        if (entry?.isIntersecting) {
          setVisible(true);
          io.disconnect();
        }
      },
      { rootMargin },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [rootMargin, visible]);

  useEffect(() => {
    if (!visible || !eagerHash || !shouldScrollRef.current) return;
    if (!hashMatches(eagerHash)) return;

    const id = eagerHash.slice(1);
    const timer = window.setTimeout(() => {
      document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
      shouldScrollRef.current = false;
    }, 80);

    return () => window.clearTimeout(timer);
  }, [visible, eagerHash, children]);

  return (
    <div
      ref={ref}
      className={cn(className, !visible && placeholderClassName)}
      style={!visible && minHeight != null ? { minHeight } : undefined}
    >
      {visible ? children : null}
    </div>
  );
}
