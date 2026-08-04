import { Code2, ExternalLink, FolderTree, Terminal } from "lucide-react";
import type { TaskAttachment } from "@/api/types";
import { DeployActions } from "@/components/deliverables/deploy-actions";
import { openDeliverable } from "@/stores/deliverable-store";

type CodebaseMeta = {
  file_tree?: string[];
  stack?: string;
  commands?: string[];
  zip_filename?: string;
  deploy?: Record<string, string>;
};

function looksLikeCodebase(files: TaskAttachment[], meta?: CodebaseMeta | null): boolean {
  if (meta?.file_tree?.length || meta?.zip_filename || meta?.stack?.includes("next")) {
    return true;
  }
  return files.some((f) => {
    const n = f.name.toLowerCase();
    return (
      n.endsWith(".zip") ||
      n.includes("codebase.md") ||
      n.includes("-package.json") ||
      n.endsWith("package.json")
    );
  });
}

/** Highlights a generated Next.js codebase: tree, npm commands, GitHub CTA. */
export function CodebaseCard({
  files,
  toolOutput,
}: {
  files: TaskAttachment[];
  toolOutput?: Record<string, unknown> | null;
}) {
  const meta = (toolOutput ?? null) as CodebaseMeta | null;
  if (!looksLikeCodebase(files, meta)) return null;

  const zip = files.find((f) => f.name.toLowerCase().endsWith(".zip"));
  const html = files.find(
    (f) => f.mime_type?.includes("html") || f.name.toLowerCase().endsWith(".html"),
  );
  const tree =
    meta?.file_tree?.slice(0, 16) ??
    files
      .filter((f) => !f.name.toLowerCase().endsWith(".html"))
      .map((f) => f.name)
      .slice(0, 12);
  const commands = meta?.commands ?? ["npm install", "npm run dev", "npm run build"];
  const stack = meta?.stack ?? "React + Next.js + TypeScript";

  return (
    <div className="space-y-2 rounded-xl border border-primary/25 bg-primary/5 px-3.5 py-3">
      <div className="flex items-center gap-1.5">
        <Code2 size={13} className="text-primary" />
        <p className="text-[11px] font-semibold uppercase tracking-wider text-text-muted">
          Full codebase
        </p>
      </div>
      <p className="text-[11px] leading-snug text-text-secondary">
        A complete <span className="font-medium text-text">{stack}</span> project was generated —
        not just an HTML preview. Download the ZIP, push to GitHub, then run locally or deploy.
      </p>

      {tree.length > 0 && (
        <div className="rounded-lg bg-bg-deep/50 px-2.5 py-2">
          <div className="mb-1 flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wide text-text-muted">
            <FolderTree size={11} /> Project tree
          </div>
          <ul className="max-h-36 space-y-0.5 overflow-auto font-mono text-[10px] text-text-secondary">
            {tree.map((path) => (
              <li key={path} className="truncate">
                {path}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="rounded-lg bg-bg-deep/50 px-2.5 py-2">
        <div className="mb-1 flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wide text-text-muted">
          <Terminal size={11} /> Local
        </div>
        <pre className="font-mono text-[10px] leading-relaxed text-text">
          {commands.join("\n")}
        </pre>
      </div>

      <DeployActions
        fileName={zip?.name ?? meta?.zip_filename ?? "project.zip"}
        onPreview={
          html
            ? () =>
                openDeliverable({
                  id: html.id,
                  name: html.name,
                  mime_type: html.mime_type,
                })
            : undefined
        }
        showGithub
        showNpmHints
        zipName={zip?.name}
      />

      {zip && (
        <a
          href={`/api/drive/${zip.id}/download`}
          className="inline-flex items-center gap-1 text-[11px] font-medium text-primary hover:underline"
        >
          Download {zip.name}
          <ExternalLink size={11} />
        </a>
      )}
    </div>
  );
}
