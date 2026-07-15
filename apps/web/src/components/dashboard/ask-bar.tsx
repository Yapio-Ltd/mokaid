import { useCallback, useEffect, useRef, useState, type ClipboardEvent, type DragEvent, type KeyboardEvent } from "react";
import { ArrowUp, Plus, X } from "lucide-react";
import { DropDispatchModal } from "@/components/modals/drop-dispatch-modal";
import { cn } from "@/lib/cn";
import { parserForFile } from "@/lib/file-parsers";
import { fileIcon, formatFileSize } from "@/lib/file-ui";

interface PendingFile {
  id: string;
  file: File;
  previewUrl?: string;
}

function makePending(file: File): PendingFile {
  return {
    id: `${file.name}-${file.size}-${file.lastModified}-${Math.random().toString(36).slice(2, 8)}`,
    file,
    previewUrl: file.type.startsWith("image/") ? URL.createObjectURL(file) : undefined,
  };
}

export function AskBar() {
  const [text, setText] = useState("");
  const [pending, setPending] = useState<PendingFile[]>([]);
  const [focused, setFocused] = useState(false);
  const [dragOver, setDragOver] = useState(false);
  const [dispatchOpen, setDispatchOpen] = useState(false);
  const [dispatchFiles, setDispatchFiles] = useState<File[]>([]);
  const [dispatchInstruction, setDispatchInstruction] = useState("");

  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const dragDepth = useRef(0);

  // Revoke object URLs when chips are removed / unmounted.
  useEffect(() => {
    return () => {
      pending.forEach((p) => {
        if (p.previewUrl) URL.revokeObjectURL(p.previewUrl);
      });
    };
    // Intentionally only on unmount — chip removals revoke individually.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const resize = useCallback(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, 144)}px`;
  }, []);

  useEffect(() => {
    resize();
  }, [text, resize]);

  const addFiles = useCallback((list: FileList | File[]) => {
    const next = Array.from(list).map(makePending);
    if (next.length === 0) return;
    setPending((prev) => [...prev, ...next]);
  }, []);

  const removeFile = useCallback((id: string) => {
    setPending((prev) => {
      const target = prev.find((p) => p.id === id);
      if (target?.previewUrl) URL.revokeObjectURL(target.previewUrl);
      return prev.filter((p) => p.id !== id);
    });
  }, []);

  const canSubmit = text.trim().length > 0 || pending.length > 0;

  const submit = useCallback(() => {
    if (!canSubmit) return;
    setDispatchInstruction(text.trim());
    setDispatchFiles(pending.map((p) => p.file));
    setDispatchOpen(true);
  }, [canSubmit, text, pending]);

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  };

  const onPaste = (e: ClipboardEvent<HTMLTextAreaElement>) => {
    const items = e.clipboardData?.items;
    if (!items) return;
    const files: File[] = [];
    for (const item of Array.from(items)) {
      if (item.kind === "file") {
        const file = item.getAsFile();
        if (file) files.push(file);
      }
    }
    if (files.length > 0) {
      e.preventDefault();
      addFiles(files);
    }
  };

  const onDragEnter = (e: DragEvent) => {
    if (![...e.dataTransfer.types].includes("Files")) return;
    e.preventDefault();
    dragDepth.current += 1;
    setDragOver(true);
  };

  const onDragLeave = (e: DragEvent) => {
    if (![...e.dataTransfer.types].includes("Files")) return;
    e.preventDefault();
    dragDepth.current = Math.max(0, dragDepth.current - 1);
    if (dragDepth.current === 0) setDragOver(false);
  };

  const onDragOver = (e: DragEvent) => {
    if (![...e.dataTransfer.types].includes("Files")) return;
    e.preventDefault();
  };

  const onDrop = (e: DragEvent) => {
    if (![...e.dataTransfer.types].includes("Files")) return;
    e.preventDefault();
    dragDepth.current = 0;
    setDragOver(false);
    if (e.dataTransfer.files.length > 0) addFiles(e.dataTransfer.files);
  };

  const handleDispatchOpenChange = (open: boolean) => {
    setDispatchOpen(open);
    if (!open) {
      // Clear the bar after a successful or cancelled dispatch session.
      pending.forEach((p) => {
        if (p.previewUrl) URL.revokeObjectURL(p.previewUrl);
      });
      setPending([]);
      setText("");
      setDispatchFiles([]);
      setDispatchInstruction("");
    }
  };

  return (
    <>
      <div className="mx-auto w-full max-w-3xl">
        <p className="mb-3 text-center text-sm font-medium text-text-secondary/80">
          Ready when you are.
        </p>

        <div
          onDragEnter={onDragEnter}
          onDragLeave={onDragLeave}
          onDragOver={onDragOver}
          onDrop={onDrop}
          className={cn(
            "relative overflow-hidden rounded-2xl border transition-all duration-300",
            "bg-surface/55 backdrop-blur-xl",
            focused || dragOver
              ? "border-primary/40 shadow-[0_0_0_1px_rgba(124,92,255,0.2),0_0_40px_-8px_rgba(124,92,255,0.35)]"
              : "border-white/[0.08] shadow-[0_8px_32px_-12px_rgba(0,0,0,0.55)]",
            dragOver && "bg-primary-muted/20",
          )}
        >
          {/* Top luminous hairline */}
          <span
            aria-hidden
            className={cn(
              "pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent to-transparent",
              focused || dragOver ? "via-primary/70" : "via-white/15",
            )}
          />

          {pending.length > 0 && (
            <div className="flex flex-wrap gap-2 border-b border-white/[0.05] px-3.5 pt-3 pb-2.5">
              {pending.map((item) => {
                const Icon = fileIcon(item.file);
                const parser = parserForFile(item.file.name, item.file.type);
                return (
                  <span
                    key={item.id}
                    className="group/chip relative flex max-w-[220px] items-center gap-2 rounded-xl border border-white/[0.08] bg-bg-deep/50 px-2 py-1.5"
                  >
                    {item.previewUrl ? (
                      <img
                        src={item.previewUrl}
                        alt=""
                        className="h-8 w-8 shrink-0 rounded-lg object-cover"
                      />
                    ) : (
                      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary-muted/40 text-primary-light">
                        <Icon size={14} />
                      </span>
                    )}
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[11px] font-medium text-text">
                        {item.file.name}
                      </span>
                      <span className="block text-[10px] text-text-muted">
                        {formatFileSize(item.file.size)} · {parser.label}
                      </span>
                    </span>
                    <button
                      type="button"
                      onClick={() => removeFile(item.id)}
                      className="flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-text-muted transition-colors hover:bg-white/10 hover:text-text mk-focus-ring"
                      aria-label={`Remove ${item.file.name}`}
                    >
                      <X size={12} />
                    </button>
                  </span>
                );
              })}
            </div>
          )}

          <div className="flex items-end gap-2 px-2.5 py-2.5">
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              className="mb-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full text-text-secondary transition-colors hover:bg-white/[0.06] hover:text-text mk-focus-ring"
              aria-label="Add photos and files"
              title="Add photos & files"
            >
              <Plus size={18} strokeWidth={1.75} />
            </button>
            <input
              ref={fileInputRef}
              type="file"
              multiple
              className="hidden"
              onChange={(e) => {
                if (e.target.files) addFiles(e.target.files);
                e.target.value = "";
              }}
            />

            <textarea
              ref={textareaRef}
              rows={1}
              value={text}
              onChange={(e) => setText(e.target.value)}
              onKeyDown={onKeyDown}
              onPaste={onPaste}
              onFocus={() => setFocused(true)}
              onBlur={() => setFocused(false)}
              placeholder="Ask Mokaid — describe a task, attach files…"
              className={cn(
                "max-h-36 min-h-[36px] flex-1 resize-none bg-transparent py-2 text-sm leading-relaxed text-text",
                "placeholder:text-text-muted/70 focus:outline-none",
              )}
            />

            <button
              type="button"
              onClick={submit}
              disabled={!canSubmit}
              className={cn(
                "mb-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full transition-all duration-200 mk-focus-ring",
                canSubmit
                  ? "bg-primary text-white shadow-glow hover:scale-105"
                  : "bg-white/[0.06] text-text-muted cursor-not-allowed",
              )}
              aria-label="Send request"
            >
              <ArrowUp size={16} strokeWidth={2.25} />
            </button>
          </div>

          {dragOver && (
            <div className="pointer-events-none absolute inset-0 z-10 flex items-center justify-center rounded-2xl bg-primary-muted/40 backdrop-blur-[2px]">
              <p className="text-sm font-medium text-primary-light">Drop files to attach</p>
            </div>
          )}
        </div>
      </div>

      <DropDispatchModal
        open={dispatchOpen}
        onOpenChange={handleDispatchOpenChange}
        files={dispatchFiles}
        initialInstruction={dispatchInstruction}
        autoAnalyze
      />
    </>
  );
}
