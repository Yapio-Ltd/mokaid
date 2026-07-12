import type { ReactNode } from "react";
import { AnimatePresence } from "framer-motion";
import { X } from "lucide-react";
import { cn } from "@/lib/cn";
import { SlidePanel } from "./motion";
import { Button } from "./button";

interface DetailPanelProps {
  open: boolean;
  onClose: () => void;
  title?: string;
  children: ReactNode;
  className?: string;
  /** When true, the panel floats above the page content instead of pushing it. */
  overlay?: boolean;
}

/** Right-side detail panel used across Agents, Tasks, Projects, Knowledge, Drive. */
export function DetailPanel({ open, onClose, title, children, className, overlay }: DetailPanelProps) {
  return (
    <AnimatePresence>
      {open && (
        <SlidePanel
          className={cn(
            "flex w-[440px] shrink-0 flex-col overflow-hidden rounded-2xl bg-surface shadow-[0_8px_40px_rgba(0,0,0,0.3)]",
            overlay && "fixed bottom-5 right-5 top-[80px] z-30",
            className,
          )}
        >
          <div className="flex items-center justify-between px-5 py-3.5">
            <h2 className="text-sm font-semibold text-text">{title}</h2>
            <Button variant="ghost" size="icon" onClick={onClose} aria-label="Close panel">
              <X size={16} />
            </Button>
          </div>
          <div className="flex-1 overflow-y-auto">{children}</div>
        </SlidePanel>
      )}
    </AnimatePresence>
  );
}
