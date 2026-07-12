import { useEffect, useState } from "react";
import {
  Download,
  ExternalLink,
  File as FileIcon,
  FileCode,
  FileSpreadsheet,
  FileText,
  FolderInput,
  Image as ImageIcon,
  Loader2,
} from "lucide-react";
import type { ChatAttachment } from "@/api/types";
import { fetchDriveFileBlob } from "@/api/client";
import { SaveToDriveModal } from "@/components/modals/save-to-drive-modal";
import { cn } from "@/lib/cn";

function iconFor(name: string | null, mime: string | null) {
  const ext = name?.split(".").pop()?.toLowerCase() ?? "";
  if (mime?.startsWith("image/")) return ImageIcon;
  if (["html", "htm", "css", "js", "ts", "tsx", "json", "py"].includes(ext)) return FileCode;
  if (["csv", "xlsx", "xls"].includes(ext)) return FileSpreadsheet;
  if (mime === "application/pdf" || ["pdf", "doc", "docx", "md", "txt"].includes(ext))
    return FileText;
  return FileIcon;
}

function formatSize(bytes: number | null): string {
  if (!bytes) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/**
 * A deliverable inside a chat bubble: inline image preview, compact file card,
 * and quick actions — open/preview, download locally, or file into a Drive
 * folder of your choice.
 */
export function ChatAttachmentView({
  attachment,
  tone,
}: {
  attachment: ChatAttachment;
  tone: "agent" | "member";
}) {
  const { drive_item_id: id, name, mime_type: mime } = attachment;
  const isImage = mime?.startsWith("image/") ?? false;
  const isText =
    mime?.startsWith("text/") ||
    ["md", "txt", "json", "csv", "html", "htm"].includes(name?.split(".").pop()?.toLowerCase() ?? "");
  const openable = isImage || mime === "application/pdf" || (name?.endsWith(".html") ?? false);

  const [blobUrl, setBlobUrl] = useState<string | null>(null);
  const [textPreview, setTextPreview] = useState<string | null>(null);
  const [previewOpen, setPreviewOpen] = useState(false);
  const [saveOpen, setSaveOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (!isImage) return;
    let alive = true;
    let url: string | null = null;
    fetchDriveFileBlob(id)
      .then((blob) => {
        url = URL.createObjectURL(blob);
        if (alive) setBlobUrl(url);
        else URL.revokeObjectURL(url);
      })
      .catch(() => alive && setFailed(true));
    return () => {
      alive = false;
      if (url) URL.revokeObjectURL(url);
    };
  }, [id, isImage]);

  const ensureUrl = async (): Promise<string> => {
    if (blobUrl) return blobUrl;
    const blob = await fetchDriveFileBlob(id);
    const url = URL.createObjectURL(blob);
    setBlobUrl(url);
    return url;
  };

  const openPreview = async () => {
    if (isText && !textPreview) {
      setBusy(true);
      try {
        const blob = await fetchDriveFileBlob(id);
        const text = await blob.text();
        setTextPreview(text.slice(0, 4000));
        setPreviewOpen(true);
      } catch {
        setFailed(true);
      } finally {
        setBusy(false);
      }
      return;
    }
    if (isText && textPreview) {
      setPreviewOpen((v) => !v);
      return;
    }
    await handleOpen();
  };

  const handleOpen = async () => {
    setBusy(true);
    setFailed(false);
    try {
      const url = await ensureUrl();
      if (openable) {
        window.open(url, "_blank", "noopener");
      } else {
        const a = document.createElement("a");
        a.href = url;
        a.download = name ?? "download";
        document.body.appendChild(a);
        a.click();
        a.remove();
      }
    } catch {
      setFailed(true);
    } finally {
      setBusy(false);
    }
  };

  const handleDownload = async (e: React.MouseEvent) => {
    e.stopPropagation();
    setBusy(true);
    setFailed(false);
    try {
      const url = await ensureUrl();
      const a = document.createElement("a");
      a.href = url;
      a.download = name ?? "download";
      document.body.appendChild(a);
      a.click();
      a.remove();
    } catch {
      setFailed(true);
    } finally {
      setBusy(false);
    }
  };

  const actionBtn = cn(
    "rounded p-1 transition-colors",
    tone === "member"
      ? "text-white/70 hover:bg-white/15 hover:text-white"
      : "text-text-muted hover:bg-surface-hover hover:text-text",
  );

  if (isImage) {
    return (
      <div className="mt-1.5">
        <button
          type="button"
          onClick={handleOpen}
          className="block overflow-hidden rounded-lg border border-border-strong/50 transition-opacity hover:opacity-90"
          title={`Open ${name ?? "image"}`}
        >
          {blobUrl ? (
            <img
              src={blobUrl}
              alt={name ?? "attachment"}
              className="max-h-48 w-full max-w-[240px] object-cover"
            />
          ) : (
            <span className="flex h-24 w-[240px] items-center justify-center bg-surface-overlay">
              {failed ? (
                <span className="text-[11px] text-danger">Preview unavailable</span>
              ) : (
                <Loader2 size={16} className="animate-spin text-text-muted" />
              )}
            </span>
          )}
        </button>
        <div className="mt-1 flex gap-1">
          <button type="button" title="Save to Drive" className={actionBtn} onClick={() => setSaveOpen(true)}>
            <FolderInput size={12} />
          </button>
          <button type="button" title="Download" className={actionBtn} onClick={handleDownload}>
            <Download size={12} />
          </button>
        </div>
        <SaveToDriveModal open={saveOpen} onOpenChange={setSaveOpen} itemIds={[id]} itemLabel={name ?? undefined} />
      </div>
    );
  }

  const Icon = iconFor(name, mime);

  return (
    <div className="mt-1.5">
      <div
        className={cn(
          "flex w-full items-center gap-2.5 rounded-lg border px-2.5 py-2 text-left transition-colors",
          tone === "member"
            ? "border-white/20 bg-white/10"
            : "border-border bg-surface",
        )}
      >
        <button type="button" onClick={() => void openPreview()} className="flex min-w-0 flex-1 items-center gap-2.5">
          <span
            className={cn(
              "flex h-8 w-8 shrink-0 items-center justify-center rounded-md",
              tone === "member" ? "bg-white/15 text-white" : "bg-primary-muted text-primary-light",
            )}
          >
            <Icon size={16} />
          </span>
          <span className="min-w-0 flex-1">
            <span
              className={cn(
                "block truncate text-[12px] font-medium",
                tone === "member" ? "text-white" : "text-text",
              )}
            >
              {name ?? "file"}
            </span>
            <span
              className={cn(
                "block text-[10px]",
                tone === "member" ? "text-white/70" : "text-text-muted",
              )}
            >
              {failed ? "Failed — retry" : formatSize(attachment.size_bytes) || "file"}
            </span>
          </span>
        </button>
        {busy ? (
          <Loader2
            size={14}
            className={cn("animate-spin", tone === "member" ? "text-white/80" : "text-text-muted")}
          />
        ) : (
          <span className="flex shrink-0 items-center gap-0.5">
            <button type="button" title="Save to Drive" className={actionBtn} onClick={() => setSaveOpen(true)}>
              <FolderInput size={12} />
            </button>
            <button type="button" title="Download locally" className={actionBtn} onClick={handleDownload}>
              <Download size={12} />
            </button>
            <button type="button" title={openable ? "Open" : "Preview"} className={actionBtn} onClick={() => void openPreview()}>
              <ExternalLink size={12} />
            </button>
          </span>
        )}
      </div>
      {previewOpen && textPreview && (
        <pre
          className={cn(
            "mt-1 max-h-36 overflow-y-auto rounded-lg border px-2.5 py-2 text-[10px] leading-relaxed",
            tone === "member"
              ? "border-white/20 bg-white/5 text-white/90"
              : "border-border bg-surface-raised text-text-secondary",
          )}
        >
          {textPreview}
        </pre>
      )}
      <SaveToDriveModal open={saveOpen} onOpenChange={setSaveOpen} itemIds={[id]} itemLabel={name ?? undefined} />
    </div>
  );
}
