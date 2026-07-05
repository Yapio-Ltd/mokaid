import { cn } from "@/lib/cn";

export function LogoMark({ size = 32, className }: { size?: number; className?: string }) {
  return (
    <img
      src="/branding/logo-without-bg.png"
      alt="mokaid"
      width={size}
      height={size}
      className={cn("shrink-0 object-contain", className)}
      draggable={false}
    />
  );
}

export function Logo({ collapsed = false }: { collapsed?: boolean }) {
  return (
    <div className="flex items-center gap-2.5">
      <LogoMark size={30} />
      {!collapsed && (
        <span className="text-[17px] font-bold tracking-tight text-text">mokaid</span>
      )}
    </div>
  );
}
