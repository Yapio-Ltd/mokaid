import { useId, useEffect, useRef, useState, type ReactNode } from "react";
import { cn } from "@/lib/cn";

const FACE_PX = { xs: 28, sm: 40, md: 48, lg: 64, xl: 96 } as const;

const RING_DIMS = {
  xs: { gutter: 5, stroke: 3.5, badge: "h-3.5 min-w-3.5 text-[8px] px-0.5" },
  sm: { gutter: 6, stroke: 4, badge: "h-4 min-w-4 text-[9px] px-0.5" },
  md: { gutter: 7, stroke: 4.5, badge: "h-4.5 min-w-[18px] text-[10px] px-1" },
  lg: { gutter: 8, stroke: 5, badge: "h-5 min-w-5 text-[11px] px-1" },
  xl: { gutter: 10, stroke: 5.5, badge: "h-6 min-w-6 text-[12px] px-1" },
} as const;

/** Outer diameter of the XP ring for a given face size (no extra layout pad). */
export function agentRingOuterPx(size: keyof typeof FACE_PX): number {
  const face = FACE_PX[size];
  const { gutter } = RING_DIMS[size];
  return face + gutter * 2;
}

/**
 * XP progression ring — true geometric circle.
 * Layout box matches the ring diameter exactly so no square/pad sticks out.
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
  const uid = useId().replace(/:/g, "");
  const gradId = `${uid}-grad`;
  const glowId = `${uid}-glow`;

  const raw = xpForNext > 0 ? Math.min(Math.max(xp / xpForNext, 0), 1) : 0;
  const progress = raw > 0 ? Math.max(raw, 0.06) : 0;

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

  const face = FACE_PX[size];
  const dims = RING_DIMS[size];
  const ring = face + dims.gutter * 2;

  const radius = 50 * (1 - dims.gutter / ring);
  const strokeVb = (dims.stroke / ring) * 100;
  const circumference = 2 * Math.PI * radius;

  return (
    <span
      className={cn("relative inline-block shrink-0 overflow-visible", className)}
      style={{
        width: ring,
        height: ring,
        // No background / border-radius on the layout box — only the SVG disc paints.
      }}
      title={`Niveau ${level} — ${xp}/${xpForNext} XP`}
    >
      <svg
        width={ring}
        height={ring}
        viewBox="0 0 100 100"
        preserveAspectRatio="xMidYMid meet"
        overflow="visible"
        className={cn(
          "pointer-events-none absolute inset-0 -rotate-90 overflow-visible",
          celebrating && "animate-[mk-ring-pulse_0.8s_ease-out_2]",
        )}
        aria-hidden
      >
        <defs>
          <linearGradient id={gradId} x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" stopColor="#c4b5fd" />
            <stop offset="45%" stopColor="#8b5cf6" />
            <stop offset="100%" stopColor="#22d3ee" />
          </linearGradient>
          <filter
            id={glowId}
            x="-40%"
            y="-40%"
            width="180%"
            height="180%"
            colorInterpolationFilters="sRGB"
          >
            <feGaussianBlur in="SourceGraphic" stdDeviation="1.6" result="soft" />
            <feColorMatrix
              in="soft"
              type="matrix"
              values="1 0 0 0 0
                      0 1 0 0 0
                      0 0 1 0 0
                      0 0 0 0.65 0"
              result="glow"
            />
            <feMerge>
              <feMergeNode in="glow" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>

        {/* Disc only as large as the ring stroke — no extra plate outside. */}
        <circle
          cx="50"
          cy="50"
          r={radius + strokeVb / 2}
          fill="var(--mk-bg, #0b0b10)"
        />

        <circle
          cx="50"
          cy="50"
          r={radius}
          fill="none"
          stroke="#4a4658"
          strokeWidth={strokeVb}
          strokeLinecap="butt"
        />
        <circle
          cx="50"
          cy="50"
          r={radius}
          fill="none"
          stroke={`url(#${gradId})`}
          strokeWidth={strokeVb}
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={circumference * (1 - progress)}
          filter={`url(#${glowId})`}
          className="transition-[stroke-dashoffset] duration-700 ease-out"
        />
      </svg>

      <span
        className="absolute [corner-shape:round]"
        style={{
          width: face,
          height: face,
          left: dims.gutter,
          top: dims.gutter,
          borderRadius: "50%",
          overflow: "hidden",
          clipPath: "circle(50% at 50% 50%)",
          WebkitClipPath: "circle(50% at 50% 50%)",
        }}
      >
        {children}
      </span>

      {showBadge && (
        <span
          className={cn(
            "absolute z-10 inline-flex items-center justify-center font-bold leading-none text-white shadow-md [corner-shape:round]",
            "bg-gradient-to-br from-violet-500 to-cyan-400",
            dims.badge,
            celebrating && "animate-bounce",
          )}
          style={{
            bottom: 0,
            right: 0,
            borderRadius: "50%",
            boxShadow: "0 0 0 2px var(--mk-bg, #0b0b10)",
          }}
          aria-label={`Niveau ${level}`}
        >
          {level}
        </span>
      )}
    </span>
  );
}

export { FACE_PX as AGENT_AVATAR_FACE_PX };
