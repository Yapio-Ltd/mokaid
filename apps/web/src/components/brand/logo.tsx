import { cn } from "@/lib/cn";

export function LogoMark({ size = 32, className }: { size?: number; className?: string }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      className={cn("shrink-0", className)}
      aria-hidden
    >
      <rect width="32" height="32" rx="8" fill="url(#mk-logo-gradient)" />
      <path
        d="M8 22V11.5l4.5 6 3.5-6 3.5 6 4.5-6V22"
        stroke="#fff"
        strokeWidth="2.4"
        strokeLinecap="round"
        strokeLinejoin="round"
        fill="none"
      />
      <defs>
        <linearGradient id="mk-logo-gradient" x1="0" y1="0" x2="32" y2="32">
          <stop stopColor="#8f72ff" />
          <stop offset="1" stopColor="#5936d1" />
        </linearGradient>
      </defs>
    </svg>
  );
}

export function Logo({ collapsed = false }: { collapsed?: boolean }) {
  return (
    <div className="flex items-center gap-2.5">
      <LogoMark size={30} />
      {!collapsed && (
        <span className="text-[17px] font-bold tracking-tight text-text">
          mokaid
        </span>
      )}
    </div>
  );
}
