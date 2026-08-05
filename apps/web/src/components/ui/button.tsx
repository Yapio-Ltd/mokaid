import { forwardRef, type ButtonHTMLAttributes } from "react";
import { cn } from "@/lib/cn";
import { Loader2 } from "lucide-react";

type Variant = "primary" | "secondary" | "ghost" | "danger" | "outline";
type Size = "sm" | "md" | "lg" | "icon";

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
  loading?: boolean;
}

const variantClasses: Record<Variant, string> = {
  primary:
    "bg-primary text-white border-0 shadow-sm hover:bg-primary-dark hover:shadow-glow active:bg-primary-dark",
  // Soft violet wash — no hard outline (avoids the white cord look on dark UI)
  secondary:
    "border-0 bg-primary/[0.1] text-text hover:bg-primary/[0.16] hover:text-primary-light",
  ghost: "border-0 bg-transparent text-text-secondary hover:bg-primary/[0.08] hover:text-text",
  danger: "border-0 bg-danger/10 text-danger hover:bg-danger/18",
  outline:
    "border-0 bg-primary/[0.06] text-text-secondary shadow-[inset_0_0_0_1px_rgba(124,92,255,0.22)] hover:bg-primary/[0.12] hover:text-primary-light hover:shadow-[inset_0_0_0_1px_rgba(124,92,255,0.4)]",
};

const sizeClasses: Record<Size, string> = {
  sm: "h-8 px-3 text-xs gap-1.5",
  md: "h-9 px-4 text-sm gap-2",
  lg: "h-11 px-5 text-sm gap-2",
  icon: "h-9 w-9 p-0",
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = "primary", size = "md", loading, className, children, disabled, ...props },
  ref,
) {
  return (
    <button
      ref={ref}
      disabled={disabled || loading}
      className={cn(
        "inline-flex select-none items-center justify-center rounded-md font-medium transition-all duration-200 mk-focus-ring active:scale-[0.97] disabled:opacity-50 disabled:pointer-events-none",
        variantClasses[variant],
        sizeClasses[size],
        className,
      )}
      {...props}
    >
      {loading && <Loader2 className="h-4 w-4 animate-spin" />}
      {children}
    </button>
  );
});
