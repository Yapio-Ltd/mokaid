import { cn } from "@/lib/cn";
import { initials } from "@/lib/format";
import { Bot } from "lucide-react";

interface AvatarProps {
  name: string | null | undefined;
  src?: string | null;
  size?: "xs" | "sm" | "md" | "lg" | "xl";
  isAi?: boolean;
  color?: string;
  className?: string;
}

const sizeClasses = {
  xs: "h-6 w-6 text-[9px]",
  sm: "h-8 w-8 text-[11px]",
  md: "h-10 w-10 text-xs",
  lg: "h-14 w-14 text-base",
  xl: "h-20 w-20 text-xl",
};

const iconSizes = { xs: 12, sm: 14, md: 18, lg: 24, xl: 32 };

export function Avatar({ name, src, size = "md", isAi, color, className }: AvatarProps) {
  return (
    <span
      className={cn(
        "relative inline-flex shrink-0 items-center justify-center overflow-hidden rounded-full border border-border-strong font-semibold text-white select-none",
        sizeClasses[size],
        className,
      )}
      style={{ backgroundColor: color ?? (isAi ? "#5936d1" : "#472aa8") }}
      title={name ?? undefined}
    >
      {src ? (
        <img src={src} alt={name ?? ""} className="h-full w-full object-cover" />
      ) : isAi ? (
        <Bot size={iconSizes[size]} />
      ) : (
        initials(name)
      )}
    </span>
  );
}

export function StatusAvatar({
  status,
  ...props
}: AvatarProps & { status?: "online" | "offline" | "away" | string }) {
  const statusColor =
    status === "online" ? "bg-success" : status === "away" ? "bg-warning" : "bg-text-disabled";

  return (
    <span className="relative inline-flex">
      <Avatar {...props} />
      {status && (
        <span
          className={cn(
            "absolute bottom-0 right-0 h-2.5 w-2.5 rounded-full ring-2 ring-surface",
            statusColor,
          )}
        />
      )}
    </span>
  );
}
