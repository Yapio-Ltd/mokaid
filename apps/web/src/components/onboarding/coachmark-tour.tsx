import { useEffect, useLayoutEffect, useState } from "react";
import { ArrowLeft, ArrowRight, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useUpdateOnboarding } from "@/api/hooks";
import { useOnboardingStore } from "@/stores/onboarding-store";

interface TourStep {
  target: string;
  title: string;
  body: string;
}

const tourSteps: TourStep[] = [
  {
    target: "nav-dashboard",
    title: "Your virtual office",
    body: "The dashboard shows your team, humans and AI agents, at work in real time.",
  },
  {
    target: "nav-projects",
    title: "Projects",
    body: "Group tasks, agents and files around one goal. Create as many as you need.",
  },
  {
    target: "new-task",
    title: "Create tasks anywhere",
    body: "Describe what you need in plain language and assign it to an agent. It will reply right away.",
  },
  {
    target: "nav-agents",
    title: "Your AI agents",
    body: "Hire, configure and monitor agents. Assign them a task and they start working right away.",
  },
  {
    target: "nav-integrations",
    title: "MCP Hub",
    body: "Connect tools like Figma, GitHub or Slack, and choose exactly which agent can use which tool.",
  },
  {
    target: "nav-settings",
    title: "Workspace settings",
    body: "Fine-tune features, working hours and permissions. You can replay this tour from here anytime.",
  },
];

interface Rect {
  top: number;
  left: number;
  width: number;
  height: number;
}

export function CoachmarkTour() {
  const tourActive = useOnboardingStore((s) => s.tourActive);
  const tourStep = useOnboardingStore((s) => s.tourStep);
  const nextTourStep = useOnboardingStore((s) => s.nextTourStep);
  const prevTourStep = useOnboardingStore((s) => s.prevTourStep);
  const stopTour = useOnboardingStore((s) => s.stopTour);
  const updateOnboarding = useUpdateOnboarding();

  const step = tourSteps[tourStep];
  const [rect, setRect] = useState<Rect | null>(null);

  const endTour = () => {
    stopTour();
    updateOnboarding.mutate({ tour_done: true });
  };

  useLayoutEffect(() => {
    if (!tourActive || !step) return;
    const measure = () => {
      const el = document.querySelector(`[data-tour="${step.target}"]`);
      if (!el) {
        setRect(null);
        return;
      }
      const r = el.getBoundingClientRect();
      setRect({ top: r.top, left: r.left, width: r.width, height: r.height });
    };
    measure();
    window.addEventListener("resize", measure);
    window.addEventListener("scroll", measure, true);
    return () => {
      window.removeEventListener("resize", measure);
      window.removeEventListener("scroll", measure, true);
    };
  }, [tourActive, tourStep, step]);

  // If the anchor is missing (e.g. collapsed sidebar), skip that step.
  useEffect(() => {
    if (!tourActive || !step) return;
    const el = document.querySelector(`[data-tour="${step.target}"]`);
    if (!el) {
      if (tourStep < tourSteps.length - 1) nextTourStep();
      else endTour();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tourActive, tourStep, step, nextTourStep]);

  if (!tourActive || !step || !rect) return null;

  const isLast = tourStep === tourSteps.length - 1;
  const pad = 6;
  const tooltipLeft = Math.min(rect.left + rect.width + 14, window.innerWidth - 320);
  const tooltipTop = Math.min(Math.max(rect.top - 8, 12), window.innerHeight - 190);

  return (
    <div className="fixed inset-0 z-[90]">
      {/* Spotlight: darken everything except the target */}
      <div
        className="absolute rounded-xl ring-2 ring-primary transition-all duration-300"
        style={{
          top: rect.top - pad,
          left: rect.left - pad,
          width: rect.width + pad * 2,
          height: rect.height + pad * 2,
          boxShadow: "0 0 0 9999px rgba(8, 8, 16, 0.72)",
        }}
      />

      <div
        className="absolute w-[300px] rounded-2xl bg-surface-overlay p-4 shadow-[0_12px_48px_rgba(0,0,0,0.4)] mk-fade-up"
        style={{ top: tooltipTop, left: tooltipLeft }}
      >
        <button
          onClick={endTour}
          aria-label="Close tour"
          className="absolute right-2.5 top-2.5 rounded-lg p-1 text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
        >
          <X size={13} />
        </button>
        <p className="text-[10px] font-semibold uppercase tracking-widest text-primary-light">
          {tourStep + 1} / {tourSteps.length}
        </p>
        <h3 className="mt-1.5 pr-5 text-sm font-bold text-text">{step.title}</h3>
        <p className="mt-1 text-xs leading-relaxed text-text-secondary">{step.body}</p>
        <div className="mt-3.5 flex items-center justify-between">
          <div className="flex gap-1">
            {tourSteps.map((_, i) => (
              <span
                key={i}
                className={
                  i === tourStep
                    ? "h-1.5 w-4 rounded-full bg-primary"
                    : "h-1.5 w-1.5 rounded-full bg-border-strong"
                }
              />
            ))}
          </div>
          <div className="flex gap-1.5">
            {tourStep > 0 && (
              <Button variant="ghost" size="sm" onClick={prevTourStep}>
                <ArrowLeft size={13} />
              </Button>
            )}
            <Button size="sm" onClick={() => (isLast ? endTour() : nextTourStep())}>
              {isLast ? "Done" : "Next"} {!isLast && <ArrowRight size={13} />}
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
