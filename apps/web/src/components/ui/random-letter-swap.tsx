import { useEffect, useMemo, useState } from "react";
import { motion, type Transition } from "framer-motion";
import { cn } from "@/lib/cn";

const GLYPHS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

export type RandomLetterSwapProps = {
  label: string;
  className?: string;
  /** Seconds between each letter starting its scramble. */
  staggerDuration?: number;
  reverse?: boolean;
  transition?: Transition;
};

/**
 * Hover text effect: letters scramble briefly then settle back to the label.
 * Used on landing nav (framer-motion).
 */
export function RandomLetterSwap({
  label,
  className,
  staggerDuration = 0.025,
  reverse = false,
  transition = { duration: 0.6, type: "spring", bounce: 0 },
}: RandomLetterSwapProps) {
  const [hovered, setHovered] = useState(false);
  const [reduced, setReduced] = useState(false);
  const letters = useMemo(() => Array.from(label), [label]);

  useEffect(() => {
    setReduced(window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }, []);

  return (
    <span
      className={cn("inline-flex whitespace-nowrap", className)}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onFocus={() => setHovered(true)}
      onBlur={() => setHovered(false)}
      aria-label={label}
    >
      {letters.map((char, i) => {
        const order = reverse ? letters.length - 1 - i : i;
        return (
          <SwapLetter
            key={`${label}-${i}`}
            char={char}
            active={hovered && !reduced}
            delay={order * staggerDuration}
            transition={transition}
          />
        );
      })}
    </span>
  );
}

function SwapLetter({
  char,
  active,
  delay,
  transition,
}: {
  char: string;
  active: boolean;
  delay: number;
  transition: Transition;
}) {
  const [display, setDisplay] = useState(char === " " ? "\u00a0" : char);

  useEffect(() => {
    if (char === " ") {
      setDisplay("\u00a0");
      return;
    }

    if (!active) {
      setDisplay(char);
      return;
    }

    let intervalId = 0;
    let frame = 0;
    const cycles = 5;

    const timeoutId = window.setTimeout(() => {
      intervalId = window.setInterval(() => {
        frame += 1;
        if (frame >= cycles) {
          setDisplay(char);
          window.clearInterval(intervalId);
        } else {
          setDisplay(GLYPHS[Math.floor(Math.random() * GLYPHS.length)] ?? char);
        }
      }, 42);
    }, delay * 1000);

    return () => {
      window.clearTimeout(timeoutId);
      window.clearInterval(intervalId);
    };
  }, [active, char, delay]);

  if (char === " ") {
    return <span className="inline-block w-[0.28em]">{"\u00a0"}</span>;
  }

  return (
    <motion.span
      className="inline-block"
      initial={false}
      animate={active ? { y: [0, -3, 0] } : { y: 0 }}
      transition={{ ...transition, delay }}
    >
      {display}
    </motion.span>
  );
}

export default RandomLetterSwap;
