import { useEffect, useMemo, useState } from "react";
import { AnimatePresence, motion, useReducedMotion } from "framer-motion";
import { cn } from "@/lib/cn";

type TextMorphProps = {
  words?: string[];
  interval?: number;
  className?: string;
  charClassName?: string;
};

const defaultWords = ["engineer", "developer", "designer"];

export function TextMorph({
  words = defaultWords,
  interval = 2500,
  className,
  charClassName,
}: TextMorphProps) {
  const [index, setIndex] = useState(0);
  const reducedMotion = useReducedMotion();

  useEffect(() => {
    if (!words.length) return;
    if (reducedMotion) return;

    const timer = setInterval(() => {
      setIndex((prev) => (prev + 1) % words.length);
    }, interval);

    return () => clearInterval(timer);
  }, [words, interval, reducedMotion]);

  const chars = useMemo(() => {
    return Array.from(words[index] ?? "");
  }, [index, words]);

  if (!words.length) return null;

  if (reducedMotion) return <span className={cn("inline-flex", className)}>{words[0]}</span>;

  return (
    <AnimatePresence mode="popLayout" initial={false}>
      <motion.span
        key={index}
        className={cn("inline-flex gap-[0.5px] overflow-hidden", className)}
        initial={{ opacity: 0, y: 5 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0, y: -5 }}
        transition={{ duration: 0.35 }}
      >
        {chars.map((char, i) => (
          <motion.span
            key={`${index}-${i}-${char}`}
            className={cn(char === " " ? "w-[0.3em]" : undefined, charClassName)}
            initial={{ opacity: 0, y: 5 }}
            animate={{ opacity: 1, y: 0 }}
            exit={{ opacity: 0, y: -5 }}
            transition={{
              delay: i * 0.025,
              duration: 0.25,
            }}
          >
            {char === " " ? "\u00a0" : char}
          </motion.span>
        ))}
      </motion.span>
    </AnimatePresence>
  );
}

export default TextMorph;
