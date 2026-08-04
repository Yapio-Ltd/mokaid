import { useEffect, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { AlertTriangle, Download, ExternalLink, FileText, Loader2, X } from "lucide-react";
import { fetchDriveFileBlob } from "@/api/client";
import { MarkdownView } from "@/components/ui/markdown-view";
import { Button } from "@/components/ui/button";
import { useDeliverableStore, type DeliverableFile } from "@/stores/deliverable-store";
import { isTextPreviewable } from "@/lib/file-parsers";

type ViewKind = "pdf" | "image" | "html" | "markdown" | "text" | "other";

function viewKind(file: DeliverableFile): ViewKind {
  const name = file.name.toLowerCase();
  const mime = file.mime_type ?? "";
  if (mime === "application/pdf" || name.endsWith(".pdf")) return "pdf";
  if (mime.startsWith("image/")) return "image";
  if (mime === "text/html" || name.endsWith(".html") || name.endsWith(".htm")) return "html";
  if (mime === "text/markdown" || name.endsWith(".md")) return "markdown";
  if (isTextPreviewable(file.name, file.mime_type)) return "text";
  return "other";
}

/**
 * Immersive full-height drawer for deliverables: PDFs render in the native
 * viewer, images full-panel, websites in a sandboxed iframe, markdown with
 * rich formatting. Opened from task outputs, chat attachments, or
 * automatically when an agent finishes a mission.
 */
export function DeliverableViewer() {
  const file = useDeliverableStore((s) => s.file);
  const close = useDeliverableStore((s) => s.closeDeliverable);

  const [blobUrl, setBlobUrl] = useState<string | null>(null);
  const [textContent, setTextContent] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(false);

  const kind = file ? viewKind(file) : null;

  // Fetch through the authenticated API; object storage may be unreachable
  // from the browser. Blob URLs are same-origin so iframes render inline.
  useEffect(() => {
    if (!file) return;
    let alive = true;
    let url: string | null = null;
    setLoading(true);
    setError(false);
    setBlobUrl(null);
    setTextContent(null);

    fetchDriveFileBlob(file.id)
      .then(async (blob) => {
        if (!alive) return;
        const currentKind = viewKind(file);
        if (currentKind === "markdown" || currentKind === "text") {
          setTextContent(await blob.text());
        } else {
          // Re-type the blob so the browser's PDF viewer engages in iframes.
          const typed =
            currentKind === "pdf" && blob.type !== "application/pdf"
              ? new Blob([blob], { type: "application/pdf" })
              : blob;
          url = URL.createObjectURL(typed);
          setBlobUrl(url);
        }
        setLoading(false);
      })
      .catch(() => {
        if (!alive) return;
        setError(true);
        setLoading(false);
      });

    return () => {
      alive = false;
      if (url) URL.revokeObjectURL(url);
    };
  }, [file]);

  // Escape closes the viewer from anywhere.
  useEffect(() => {
    if (!file) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [file, close]);

  const download = () => {
    if (!file || !blobUrl) return;
    const anchor = document.createElement("a");
    anchor.href = blobUrl;
    anchor.download = file.name;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
  };

  return (
    <AnimatePresence>
      {file && (
        <>
          <motion.button
            type="button"
            aria-label="Close viewer"
            className="fixed inset-0 z-[70] bg-black/50 backdrop-blur-[2px]"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            onClick={close}
          />
          <motion.div
            role="dialog"
            aria-label={file.name}
            className="fixed inset-y-0 right-0 z-[71] flex w-[min(960px,94vw)] flex-col border-l border-border bg-surface shadow-2xl"
            initial={{ x: "100%" }}
            animate={{ x: 0 }}
            exit={{ x: "100%" }}
            transition={{ type: "spring", stiffness: 380, damping: 36 }}
          >
            {/* Header */}
            <div className="flex shrink-0 items-center gap-2.5 border-b border-border px-4 py-3">
              <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary-muted/40 text-primary-light">
                <FileText size={15} />
              </span>
              <span className="min-w-0 flex-1 truncate text-sm font-semibold text-text">
                {file.name}
              </span>
              {blobUrl && (
                <>
                  <Button variant="ghost" size="sm" onClick={download} title="Download">
                    <Download size={13} />
                  </Button>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => window.open(blobUrl, "_blank", "noopener")}
                    title="Open in a new tab"
                  >
                    <ExternalLink size={13} />
                  </Button>
                </>
              )}
              <Button variant="ghost" size="sm" onClick={close} aria-label="Close">
                <X size={15} />
              </Button>
            </div>

            {/* Body */}
            <div className="min-h-0 flex-1 overflow-hidden bg-bg-deep/40">
              {loading && (
                <div className="flex h-full items-center justify-center gap-2 text-sm text-text-muted">
                  <Loader2 size={16} className="animate-spin" /> Loading…
                </div>
              )}
              {error && (
                <div className="flex h-full flex-col items-center justify-center gap-2 text-sm text-text-muted">
                  <AlertTriangle size={20} className="text-danger" />
                  Could not load the file.
                </div>
              )}
              {!loading && !error && kind === "pdf" && blobUrl && (
                <iframe title={file.name} src={blobUrl} className="h-full w-full border-0" />
              )}
              {!loading && !error && kind === "image" && blobUrl && (
                <div className="flex h-full items-center justify-center overflow-auto p-6">
                  <img
                    src={blobUrl}
                    alt={file.name}
                    className="max-h-full max-w-full rounded-lg object-contain shadow-lg"
                  />
                </div>
              )}
              {!loading && !error && kind === "html" && blobUrl && (
                <iframe
                  title={file.name}
                  src={blobUrl}
                  sandbox="allow-scripts"
                  className="h-full w-full border-0 bg-white"
                />
              )}
              {!loading && !error && (kind === "markdown" || kind === "text") && textContent != null && (
                <div className="h-full overflow-y-auto px-8 py-6">
                  <div className="mx-auto max-w-2xl">
                    {kind === "markdown" ? (
                      <MarkdownView markdown={textContent} className="text-[13px]" />
                    ) : (
                      <pre className="whitespace-pre-wrap break-words font-sans text-xs leading-relaxed text-text-secondary">
                        {textContent}
                      </pre>
                    )}
                  </div>
                </div>
              )}
              {!loading && !error && kind === "other" && (
                <div className="flex h-full flex-col items-center justify-center gap-3 text-sm text-text-muted">
                  <FileText size={22} />
                  No inline preview for this format.
                  <Button variant="secondary" size="sm" onClick={download}>
                    <Download size={13} /> Download
                  </Button>
                </div>
              )}
            </div>
          </motion.div>
        </>
      )}
    </AnimatePresence>
  );
}
