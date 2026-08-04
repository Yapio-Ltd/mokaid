import { Code2, LayoutTemplate, Sparkles } from "lucide-react";
import { Button } from "@/components/ui/button";

export type SiteDeliveryOption = {
  id: string;
  label: string;
  blurb: string;
};

export type SiteDeliveryChoicePayload = {
  kind?: string;
  recommended?: string;
  reason?: string;
  options?: SiteDeliveryOption[];
};

const DEFAULT_OPTIONS: SiteDeliveryOption[] = [
  {
    id: "html",
    label: "Simple vitrine HTML",
    blurb: "Une page soignée, prévisualisable tout de suite — idéal pour une landing ou une vitrine.",
  },
  {
    id: "webapp",
    label: "Codebase complet (React + Next.js + TypeScript)",
    blurb: "Projet multi-fichiers prêt pour GitHub, npm run dev et déploiement Vercel/Render.",
  },
];

/** Two-card picker for HTML showcase vs full Next.js codebase. */
export function SiteDeliveryChoice({
  payload,
  busy,
  onChoose,
}: {
  payload: SiteDeliveryChoicePayload | null | undefined;
  busy?: boolean;
  onChoose: (delivery: "html" | "webapp") => void;
}) {
  const recommended = payload?.recommended === "html" ? "html" : "webapp";
  const options =
    Array.isArray(payload?.options) && payload!.options!.length >= 2
      ? payload!.options!
      : DEFAULT_OPTIONS;
  const reason = typeof payload?.reason === "string" ? payload.reason : null;

  return (
    <div className="space-y-3">
      {reason && (
        <p className="flex items-start gap-1.5 text-[11px] leading-snug text-text-secondary">
          <Sparkles size={12} className="mt-0.5 shrink-0 text-primary" />
          {reason}
        </p>
      )}
      <div className="grid gap-2 sm:grid-cols-2">
        {options.map((opt) => {
          const id = opt.id === "html" ? "html" : "webapp";
          const isRec = id === recommended;
          const Icon = id === "html" ? LayoutTemplate : Code2;
          return (
            <button
              key={opt.id}
              type="button"
              disabled={busy}
              onClick={() => onChoose(id)}
              className={
                "flex flex-col gap-1.5 rounded-xl border px-3.5 py-3 text-left transition-colors mk-focus-ring disabled:opacity-60 " +
                (isRec
                  ? "border-primary/50 bg-primary/10 hover:bg-primary/15"
                  : "border-border bg-surface-raised/40 hover:bg-surface-hover")
              }
            >
              <div className="flex items-center gap-1.5">
                <Icon size={14} className={isRec ? "text-primary" : "text-text-muted"} />
                <span className="text-[12px] font-semibold text-text">{opt.label}</span>
              </div>
              <p className="text-[11px] leading-snug text-text-secondary">{opt.blurb}</p>
              {isRec && (
                <span className="mt-0.5 self-start rounded-md bg-primary/15 px-1.5 py-0.5 text-[10px] font-semibold text-primary">
                  Recommended
                </span>
              )}
            </button>
          );
        })}
      </div>
      <Button
        size="sm"
        variant="ghost"
        className="w-full text-[11px] text-text-muted"
        disabled={busy}
        onClick={() => onChoose(recommended)}
      >
        Continue with recommendation
      </Button>
    </div>
  );
}

export function isSiteDeliveryChoice(
  payload: Record<string, unknown> | null | undefined,
): payload is SiteDeliveryChoicePayload & Record<string, unknown> {
  return payload?.kind === "site_delivery_choice";
}
