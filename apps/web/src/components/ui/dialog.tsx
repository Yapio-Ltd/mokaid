import * as DialogPrimitive from "@radix-ui/react-dialog";
import { X } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

interface DialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description?: string;
  children: ReactNode;
  footer?: ReactNode;
  className?: string;
}

/** App-wide modal dialog built on Radix Dialog. */
export function Dialog({
  open,
  onOpenChange,
  title,
  description,
  children,
  footer,
  className,
}: DialogProps) {
  return (
    <DialogPrimitive.Root open={open} onOpenChange={onOpenChange}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="fixed inset-0 z-50 bg-black/60 backdrop-blur-sm data-[state=open]:animate-in data-[state=open]:fade-in" />
        <DialogPrimitive.Content
          className={cn(
            "mk-dialog-in fixed left-1/2 top-1/2 z-50 w-[440px] max-w-[calc(100vw-2rem)]",
            "max-h-[min(92vh,calc(100dvh-1.5rem))] overflow-y-auto rounded-xl bg-surface shadow-lg",
            className,
          )}
        >
          <div className="flex items-start justify-between px-6 py-5 md:px-8">
            <div className="pr-4">
              <DialogPrimitive.Title className="text-base font-semibold text-text">
                {title}
              </DialogPrimitive.Title>
              {description && (
                <DialogPrimitive.Description className="mt-1 text-sm text-text-muted">
                  {description}
                </DialogPrimitive.Description>
              )}
            </div>
            <DialogPrimitive.Close
              className="rounded-md p-1 text-text-muted transition-colors hover:bg-surface-hover hover:text-text mk-focus-ring"
              aria-label="Close"
            >
              <X size={16} />
            </DialogPrimitive.Close>
          </div>
          <div className="px-6 py-5 md:px-8 md:py-6">{children}</div>
          {footer && (
            <div className="flex items-center justify-end gap-2 px-6 py-4 md:px-8">
              {footer}
            </div>
          )}
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}
