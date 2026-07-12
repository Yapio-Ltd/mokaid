import { motion, type HTMLMotionProps } from "framer-motion";
import type { ReactNode } from "react";

/** Shared easing — short, understated, SaaS-grade. */
export const mkEase = [0.22, 1, 0.36, 1] as const;

export function FadeSlide({
  children,
  className,
  delay = 0,
  y = 8,
}: {
  children: ReactNode;
  className?: string;
  delay?: number;
  y?: number;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, y }}
      animate={{ opacity: 1, y: 0 }}
      exit={{ opacity: 0, y: y * 0.5 }}
      transition={{ duration: 0.22, ease: mkEase, delay }}
      className={className}
    >
      {children}
    </motion.div>
  );
}

export function FadeIn({
  children,
  className,
  ...props
}: HTMLMotionProps<"div"> & { children: ReactNode }) {
  return (
    <motion.div
      initial={{ opacity: 0 }}
      animate={{ opacity: 1 }}
      exit={{ opacity: 0 }}
      transition={{ duration: 0.18, ease: mkEase }}
      className={className}
      {...props}
    >
      {children}
    </motion.div>
  );
}

export function SlidePanel({
  children,
  className,
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <motion.aside
      initial={{ opacity: 0, x: 24 }}
      animate={{ opacity: 1, x: 0 }}
      exit={{ opacity: 0, x: 16 }}
      transition={{ duration: 0.26, ease: mkEase }}
      className={className}
    >
      {children}
    </motion.aside>
  );
}
