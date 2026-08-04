import { ExternalLink, Rocket } from "lucide-react";

/**
 * One-click deploy partners for generated websites / static webapps.
 *
 * Real OAuth + project provisioning is a DevOps track (infra/secrets). From the
 * product we open each provider with clear next steps and attach the openable
 * deliverable so the user can paste or upload the HTML file.
 */
export function DeployActions({
  fileName,
  onPreview,
}: {
  fileName: string;
  onPreview?: () => void;
}) {
  const vercel = "https://vercel.com/new";
  const render = "https://dashboard.render.com/select-repo?type=static";
  const supabase = "https://supabase.com/dashboard/new";

  return (
    <div className="rounded-xl bg-surface-raised/50 px-3.5 py-3">
      <div className="mb-2 flex items-center gap-1.5">
        <Rocket size={13} className="text-primary" />
        <p className="text-[11px] font-semibold uppercase tracking-wider text-text-muted">
          Deploy
        </p>
      </div>
      <p className="mb-2.5 text-[11px] leading-snug text-text-secondary">
        Preview live in MOKAID, then open a hosting partner. Upload{" "}
        <span className="font-medium text-text">{fileName}</span> (or the project
        folder) after sign-in — credentials stay on your account.
      </p>
      <div className="flex flex-wrap gap-1.5">
        {onPreview && (
          <button
            type="button"
            onClick={onPreview}
            className="inline-flex items-center gap-1 rounded-lg bg-primary/12 px-2.5 py-1.5 text-[11px] font-medium text-primary transition-colors hover:bg-primary/20 mk-focus-ring"
          >
            Live preview
          </button>
        )}
        <DeployLink href={vercel} label="Vercel" />
        <DeployLink href={render} label="Render" />
        <DeployLink href={supabase} label="Supabase" />
      </div>
    </div>
  );
}

function DeployLink({ href, label }: { href: string; label: string }) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="inline-flex items-center gap-1 rounded-lg bg-surface-raised px-2.5 py-1.5 text-[11px] font-medium text-text transition-colors hover:bg-surface-hover mk-focus-ring"
    >
      {label}
      <ExternalLink size={11} className="text-text-muted" />
    </a>
  );
}
