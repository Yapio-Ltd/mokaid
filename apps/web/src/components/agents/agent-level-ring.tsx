import { useEffect, useRef, useState, type ReactNode } from "react";
import { cn } from "@/lib/cn";

/**
 * Video-game style progression ring around an AI employee's avatar: the arc
 * fills as the agent earns XP toward its next level, with a level badge in
 * the corner. When the level increases while mounted, the ring pulses to
 * celebrate.
 *
 * Wraps any avatar: `<AgentLevelRing level={3} xp={40} xpForNext={190}>…`
 */
export function AgentLevelRing({
  level,
  xp,
  xpForNext,
  size = "md",
  showBadge = true,
  className,
  children,
}: {
  level: number;
  xp: number;
  xpForNext: number;
  size?: "xs" | "sm" | "md" | "lg" | "xl";
  showBadge?: boolean;
  className?: string;
  children: ReactNode;
}) {
  const progress = xpForNext > 0 ? Math.min(Math.max(xp / xpForNext, 0), 1) : 0;

  // Level-up celebration: pulse the ring when the level changes while visible.
  const prevLevel = useRef(level);
  const [celebrating, setCelebrating] = useState(false);
  useEffect(() => {
    if (level > prevLevel.current) {
      setCelebrating(true);
      const timer = setTimeout(() => setCelebrating(false), 1600);
      return () => clearTimeout(timer);
    }
    prevLevel.current = level;
  }, [level]);
  useEffect(() => {
    prevLevel.current = level;
  }, [level]);

  const dims = {
    xs: { pad: 2, stroke: 1.5, badge: "h-3 min-w-3 text-[7px] px-0.5" },
    sm: { pad: 2.5, stroke: 2, badge: "h-3.5 min-w-3.5 text-[8px] px-0.5" },
    md: { pad: 3, stroke: 2, badge: "h-4 min-w-4 text-[9px] px-1" },
    lg: { pad: 4, stroke: 2.5, badge: "h-4.5 min-w-[18px] text-[10px] px-1" },
    xl: { pad: 5, stroke: 3, badge: "h-5 min-w-5 text-[11px] px-1" },
  }[size];

  // SVG in a 0-100 viewBox; the arc starts at 12 o'clock.
  const radius = 50 - dims.stroke * 2;
  const circumference = 2 * Math.PI * radius;

  return (
    <span
      className={cn("relative inline-flex shrink-0", className)}
      style={{ padding: dims.pad }}
      title={`Niveau ${level} — ${xp}/${xpForNext} XP`}
    >
      <svg
        viewBox="0 0 100 100"
        className={cn(
          "pointer-events-none absolute inset-0 h-full w-full -rotate-90",
          celebrating && "animate-[ping_0.8s_ease-out_2]",
        )}
        aria-hidden
      >
        <circle
          cx="50"
          cy="50"
          r={radius}
          fill="none"
          stroke="currentColor"
          strokeWidth={dims.stroke * 2}
          className="text-border"
        />
        <circle
          cx="50"
          cy="50"
          r={radius}
          fill="none"
          stroke="url(#xp-ring-gradient)"
          strokeWidth={dims.stroke * 2}
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={circumference * (1 - progress)}
          className="transition-[stroke-dashoffset] duration-700 ease-out"
        />
        <defs>
          <linearGradient id="xp-ring-gradient" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stopColor="#8b5cf6" />
            <stop offset="100%" stopColor="#22d3ee" />
          </linearGradient>
        </defs>
      </svg>

      {children}

      {showBadge && (
        <span
          className={cn(
            "absolute -bottom-0.5 -right-0.5 z-10 inline-flex items-center justify-center rounded-full bg-gradient-to-br from-violet-500 to-cyan-400 font-bold leading-none text-white ring-2 ring-surface",
            dims.badge,
            celebrating && "animate-bounce",
          )}
          aria-label={`Niveau ${level}`}
        >
          {level}
        </span>
      )}
    </span>
  );
}
