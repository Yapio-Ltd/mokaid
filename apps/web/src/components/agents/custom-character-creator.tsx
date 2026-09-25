import { useEffect, useId, useRef, useState } from "react";
import { Check, ImagePlus, Loader2, RefreshCw, Upload, X } from "lucide-react";
import {
  AVATAR_PROMPT_MAX_LENGTH,
  avatarGenerationIsActive,
  useAvatarGeneration,
  useAvatarGenerations,
  useCreateAvatarGeneration,
  validateAvatarPhoto,
  type AvatarGeneration,
  type AvatarGenerationStatus,
} from "@/api/avatar-generations";
import type { Asset3d } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";

const STATUS_LABEL: Record<AvatarGenerationStatus, string> = {
  queued: "Waiting to begin",
  generating: "Shaping your character",
  texturing: "Adding colors and details",
  rigging: "Preparing your character to move",
  saving: "Getting your character ready",
  ready: "Your character is ready",
  failed: "Character generation failed",
};
const EXAMPLES = [
  {
    label: "Creative professional",
    prompt:
      "A friendly adult creative professional with short curly hair, round glasses, a coral sweater, dark trousers and white sneakers. Stylized 3D character, full body, standing, arms slightly apart, plain background.",
  },
  {
    label: "Space explorer",
    prompt:
      "A cheerful adult space explorer in a white and blue flight suit, with short silver hair and orange boots. Stylized 3D character, full body, standing, arms slightly apart, no helmet, plain background.",
  },
];

interface Props {
  mode: "image" | "text";
  name: string;
  selectedAssetId: string;
  onSelect: (asset: Asset3d) => void;
  onReadyChange: (ready: boolean) => void;
}

export function CustomCharacterCreator({
  mode,
  name,
  selectedAssetId,
  onSelect,
  onReadyChange,
}: Props) {
  const id = useId();
  const fileInput = useRef<HTMLInputElement>(null);
  const {
    data: history = [],
    isError: historyFailed,
    refetch: reloadHistory,
  } = useAvatarGenerations();
  const generate = useCreateAvatarGeneration();
  const [file, setFile] = useState<File | null>(null);
  const [photoUrl, setPhotoUrl] = useState<string | null>(null);
  const [prompt, setPrompt] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const [requested, setRequested] = useState<AvatarGeneration | null>(null);
  const [autoSelect, setAutoSelect] = useState(false);
  const ongoing = history.find(avatarGenerationIsActive);
  const jobId = requested?.id ?? ongoing?.id ?? null;
  const current = useAvatarGeneration(jobId);
  const job = current.data ?? requested ?? ongoing;
  const busy = generate.isPending || Boolean(job && avatarGenerationIsActive(job));
  const selectedReady =
    history.some((item) => item.status === "ready" && item.asset_id === selectedAssetId) ||
    (job?.status === "ready" && job.asset_id === selectedAssetId);

  useEffect(() => {
    onReadyChange(Boolean(selectedReady) && !busy);
  }, [selectedReady, busy, onReadyChange]);

  useEffect(() => {
    if (autoSelect && job?.status === "ready" && job.asset) {
      onSelect(job.asset);
      setAutoSelect(false);
      void reloadHistory();
    }
  }, [autoSelect, job, onSelect, reloadHistory]);

  useEffect(() => {
    if (!file) {
      setPhotoUrl(null);
      return;
    }
    const url = URL.createObjectURL(file);
    setPhotoUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [file]);

  const selectFile = (next: File | undefined) => {
    if (!next || busy) return;
    const invalid = validateAvatarPhoto(next);
    setError(invalid);
    if (!invalid) setFile(next);
  };

  const start = async () => {
    if (busy) return;
    if (mode === "image" && !file) {
      setError("Choose a photo to create your character.");
      return;
    }
    if (mode === "text" && prompt.trim().length < 3) {
      setError("Describe your character in at least 3 characters.");
      return;
    }
    setError(null);
    onReadyChange(false);
    try {
      const result = await generate.mutateAsync(
        mode === "image"
          ? { mode, file: file!, name: Array.from(name.trim()).slice(0, 80).join("") || undefined }
          : { mode, prompt: prompt.trim(), name: Array.from(name.trim()).slice(0, 80).join("") || undefined },
      );
      setRequested(result);
      setAutoSelect(true);
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : "Could not start generation. Check your connection and try again.",
      );
    }
  };

  return (
    <div className="space-y-5">
      <div>
        <h3 className="text-sm font-semibold text-text">
          {mode === "image" ? "Turn a photo into your character" : "Imagine your character"}
        </h3>
        <p className="mt-1 text-xs leading-relaxed text-text-secondary">
          {mode === "image"
            ? "Use a clear photo of one person, ideally standing with their whole body visible."
            : "Describe their appearance, outfit and style. A clear, specific description works best."}
        </p>
      </div>

      {mode === "image" ? (
        <div>
          <input
            ref={fileInput}
            id={`${id}-photo`}
            type="file"
            className="sr-only"
            accept="image/jpeg,image/png"
            disabled={busy}
            aria-label="Character photo"
            onChange={(event) => {
              selectFile(event.target.files?.[0]);
              event.target.value = "";
            }}
          />
          <div
            onDragOver={(event) => {
              event.preventDefault();
              if (!busy) setDragging(true);
            }}
            onDragLeave={() => setDragging(false)}
            onDrop={(event) => {
              event.preventDefault();
              setDragging(false);
              selectFile(event.dataTransfer.files[0]);
            }}
            className={cn(
              "overflow-hidden rounded-xl border border-dashed transition-colors",
              dragging
                ? "border-primary bg-primary/10"
                : "border-border-strong bg-surface-raised/40",
            )}
          >
            {photoUrl && file ? (
              <div className="flex items-center gap-4 p-4">
                <img
                  src={photoUrl}
                  alt="Your reference photo"
                  className="h-32 w-24 shrink-0 rounded-lg object-contain"
                />
                <div className="min-w-0 flex-1 space-y-2">
                  <p className="break-words text-xs font-medium text-text">{file.name}</p>
                  <p className="text-xs text-text-secondary">
                    {(file.size / 1_000_000).toFixed(1)} MB
                  </p>
                  <Button
                    type="button"
                    size="sm"
                    variant="secondary"
                    disabled={busy}
                    onClick={() => fileInput.current?.click()}
                  >
                    Change photo
                  </Button>
                </div>
                <Button
                  type="button"
                  size="icon"
                  variant="ghost"
                  aria-label="Remove photo"
                  disabled={busy}
                  onClick={() => setFile(null)}
                >
                  <X size={16} />
                </Button>
              </div>
            ) : (
              <button
                type="button"
                disabled={busy}
                onClick={() => fileInput.current?.click()}
                className="mk-focus-ring flex min-h-44 w-full flex-col items-center justify-center gap-2 px-5 py-7 text-center disabled:opacity-50"
              >
                <ImagePlus size={28} className="mb-1 text-primary-light" aria-hidden="true" />
                <span className="text-sm font-medium text-text">Choose a photo</span>
                <span className="text-xs text-text-secondary">
                  or drag it here · JPG or PNG · up to 10 MB
                </span>
              </button>
            )}
          </div>
          <p className="mt-2 text-xs leading-relaxed text-text-muted">
            Your photo is sent to Meshy AI to generate the 3D character.
          </p>
        </div>
      ) : (
        <div className="space-y-3">
          <div>
            <label
              htmlFor={`${id}-prompt`}
              className="mb-2 block text-xs font-medium text-text-secondary"
            >
              Character description
            </label>
            <textarea
              id={`${id}-prompt`}
              value={prompt}
              onChange={(event) => setPrompt(event.target.value)}
              maxLength={AVATAR_PROMPT_MAX_LENGTH}
              disabled={busy}
              placeholder="A friendly designer with curly hair, round glasses, a coral sweater and white sneakers. Full-body, stylized 3D character…"
              aria-describedby={`${id}-prompt-hint`}
              className="mk-input min-h-36 w-full resize-y py-3 text-sm leading-relaxed disabled:opacity-60"
            />
            <p
              id={`${id}-prompt-hint`}
              className="mt-1 text-right text-xs tabular-nums text-text-muted"
            >
              {prompt.length} / {AVATAR_PROMPT_MAX_LENGTH}
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-2">
            <span className="text-xs text-text-muted">Try an idea:</span>
            {EXAMPLES.map((example) => (
              <button
                key={example.label}
                type="button"
                disabled={busy}
                onClick={() => setPrompt(example.prompt)}
                className="mk-focus-ring rounded-md bg-primary/10 px-2.5 py-2 text-xs text-primary-light transition-colors hover:bg-primary/20 disabled:opacity-50"
              >
                {example.label}
              </button>
            ))}
          </div>
        </div>
      )}

      {(error || job?.status === "failed") && (
        <div
          role="alert"
          className="rounded-lg border border-danger/30 bg-danger/10 p-3 text-xs leading-relaxed text-danger"
        >
          <p>
            {error ||
              job?.error ||
              "We could not generate this character. Try a clearer photo or a simpler description."}
          </p>
          {job?.status === "failed" && (
            <p className="mt-1">
              Adjust your {mode === "image" ? "photo" : "description"}, then generate again.
            </p>
          )}
        </div>
      )}

      {job && avatarGenerationIsActive(job) ? (
        <div className="space-y-3 rounded-xl border border-primary/30 bg-primary/5 p-4">
          <div className="flex items-center justify-between gap-3" role="status" aria-live="polite">
            <span className="flex items-center gap-2 text-sm font-medium text-text">
              <Loader2 size={16} className="animate-spin motion-reduce:animate-none" />
              {STATUS_LABEL[job.status]}
            </span>
            <span className="text-xs tabular-nums text-primary-light">
              {Math.round(job.progress)}%
            </span>
          </div>
          <div
            role="progressbar"
            aria-label="Character generation"
            aria-valuenow={job.progress}
            aria-valuemin={0}
            aria-valuemax={100}
            className="h-1.5 overflow-hidden rounded-full bg-surface-hover"
          >
            <div
              className="h-full rounded-full bg-primary transition-[width] duration-500 motion-reduce:transition-none"
              style={{ width: `${Math.max(0, Math.min(100, job.progress))}%` }}
            />
          </div>
          <p className="text-xs leading-relaxed text-text-secondary">
            This can take a few minutes. You can leave this page and return; your character will be
            saved here.
          </p>
          {current.isError && (
            <p role="alert" className="text-xs text-warning">
              Connection interrupted. We are checking again automatically; your generation
              continues.
            </p>
          )}
        </div>
      ) : (
        <div className="space-y-2">
          <Button
            type="button"
            loading={generate.isPending}
            disabled={mode === "image" ? !file : prompt.trim().length < 3}
            onClick={() => void start()}
            className="w-full sm:w-auto"
          >
            <Upload size={15} aria-hidden="true" />
            {job?.status === "failed" ? "Generate again" : "Generate 3D character"}
          </Button>
          <p className="text-xs leading-relaxed text-text-muted">
            Sized to match your team. Preview the result before creating your agent.
          </p>
        </div>
      )}

      {job?.status === "ready" && job.asset && (
        <div
          role="status"
          className="flex flex-wrap items-center justify-between gap-3 rounded-lg bg-success/10 p-3"
        >
          <span className="flex items-center gap-2 text-xs font-medium text-success">
            <Check size={15} />
            Your character is ready
          </span>
          {selectedAssetId !== job.asset.id && (
            <Button
              type="button"
              size="sm"
              variant="secondary"
              onClick={() => onSelect(job.asset!)}
            >
              Use this character
            </Button>
          )}
        </div>
      )}

      {history.some((item) => item.status === "ready" && item.asset) && (
        <div className="border-t border-border/60 pt-4">
          <h4 className="mb-2 text-xs font-medium text-text-secondary">Your saved characters</h4>
          <div className="grid grid-cols-1 gap-2 sm:grid-cols-2">
            {history
              .filter((item) => item.status === "ready" && item.asset)
              .map((item) => (
                <button
                  type="button"
                  key={item.id}
                  disabled={busy}
                  aria-pressed={item.asset_id === selectedAssetId}
                  onClick={() => onSelect(item.asset!)}
                  className={cn(
                    "mk-focus-ring flex min-h-14 items-center gap-3 rounded-lg border px-3 py-2 text-left text-xs disabled:opacity-50",
                    item.asset_id === selectedAssetId
                      ? "border-primary/70 bg-primary/10"
                      : "border-border hover:border-border-strong",
                  )}
                >
                  <span className="min-w-0 flex-1 truncate text-text">
                    {item.name || "Custom character"}
                  </span>
                  {item.asset_id === selectedAssetId ? (
                    <Check size={15} className="text-primary-light" />
                  ) : (
                    <span className="text-text-muted">Select</span>
                  )}
                </button>
              ))}
          </div>
        </div>
      )}
      {historyFailed && (
        <div className="flex flex-wrap items-center gap-2 text-xs text-text-secondary" role="alert">
          Saved characters could not be loaded.
          <Button type="button" size="sm" variant="ghost" onClick={() => void reloadHistory()}>
            <RefreshCw size={12} />
            Retry
          </Button>
        </div>
      )}
    </div>
  );
}
