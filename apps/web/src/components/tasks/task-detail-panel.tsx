import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  AlertTriangle,
  CheckCircle2,
  ChevronDown,
  ChevronRight,
  Circle,
  Clock,
  Copy,
  Download,
  Eye,
  EyeOff,
  FileText,
  FolderInput,
  Image as ImageIcon,
  Loader2,
  MessageCircle,
  Music,
  Paperclip,
  Play,
  RefreshCw,
  ShieldAlert,
  Sparkles,
  Square,
  Trash2,
  ThumbsDown,
  ThumbsUp,
  Undo2,
} from "lucide-react";
import { fetchDriveFileBlob } from "@/api/client";
import { isTextPreviewable } from "@/lib/file-parsers";
import type { Agent, TaskAttachment, TaskRunToolCall } from "@/api/types";
import {
  useAgents,
  useApproveTaskAction,
  useAttachTaskFile,
  useDeleteTask,
  useExecuteAi,
  useProjects,
  useStopTaskAi,
  useTask,
  useToggleSubtask,
  useUpdateTask,
} from "@/api/hooks";
import { SaveToDriveModal } from "@/components/modals/save-to-drive-modal";
import { DetailPanel } from "@/components/ui/detail-panel";
import { MarkdownView } from "@/components/ui/markdown-view";
import { openDeliverable } from "@/stores/deliverable-store";
import { DeployActions } from "@/components/deliverables/deploy-actions";
import { CodebaseCard } from "@/components/deliverables/codebase-card";
import {
  SiteDeliveryChoice,
  isSiteDeliveryChoice,
} from "@/components/approvals/site-delivery-choice";
import { toast } from "@/stores/toast-store";
import { motion } from "framer-motion";
import { useMissionPlanStore, type MissionPlanStep } from "@/stores/mission-plan-store";
import { useChatStore } from "@/stores/chat-store";
import { Avatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Select } from "@/components/ui/select";
import { PriorityBadge, TaskStatusBadge } from "@/components/ui/status";
import { cn } from "@/lib/cn";
import { formatBytes, formatDateTime } from "@/lib/format";
import { humanizeErrorMessage } from "@/lib/notifications";

const NO_PROJECT = "__none__";
const NO_AGENT = "__none__";

/** True when the agent's specialty or skills plausibly cover the task's
 * requested domains. Empty domains = nothing to check. */
function agentCoversDomains(agent: Agent, domains: string[] | undefined): boolean {
  if (!domains || domains.length === 0) return true;
  const specialty = String(agent.capabilities?.learning?.specialty ?? "").toLowerCase();
  const haystack = [
    specialty,
    agent.role_title ?? "",
    agent.department ?? "",
    ...(agent.skills ?? []).map((s) => s.name ?? ""),
  ]
    .join(" ")
    .toLowerCase();
  return domains.some((d) => haystack.includes(d.toLowerCase()));
}

function toDatetimeLocal(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

function fileIcon(mime: string | null) {
  if (!mime) return <FileText size={14} />;
  if (mime.startsWith("image/")) return <ImageIcon size={14} />;
  if (mime.startsWith("audio/")) return <Music size={14} />;
  return <FileText size={14} />;
}

interface ProducedDoc {
  title: string;
  content: string;
}

function producedDocs(toolCalls: TaskRunToolCall[]): ProducedDoc[] {
  return toolCalls.flatMap((call) => {
    const out = call.output;
    if (!out || typeof out !== "object") return [];
    if (call.tool === "draft_document" && typeof out.content === "string")
      return [{ title: typeof out.title === "string" ? out.title : "Document", content: out.content }];
    if (call.tool === "summarize" && typeof out.summary === "string" && out.summary)
      return [{ title: "Summary", content: out.summary }];
    if (call.tool === "generate_report" && out.report)
      return [{ title: "Report", content: JSON.stringify(out.report, null, 2) }];
    if (call.tool === "generate_website" && typeof out.filename === "string")
      return [
        {
          title: out.filename,
          content:
            typeof out.note === "string"
              ? out.note
              : "Website HTML generated — open the file in Output to preview.",
        },
      ];
    return [];
  });
}

/** Live deep-agent checklist: todos tick off in real time as the agent works. */
function MissionPlan({ steps, working }: { steps: MissionPlanStep[]; working: boolean }) {
  const done = steps.filter((s) => s.status === "completed").length;

  return (
    <div className="rounded-xl border border-border bg-surface-raised/60 px-4 py-3">
      <div className="mb-2 flex items-center justify-between">
        <span className="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-text-muted">
          <Sparkles size={11} className="text-primary-light" />
          Mission plan
        </span>
        <span className="text-[10px] tabular-nums text-text-muted">
          {done}/{steps.length}
        </span>
      </div>
      <ul className="space-y-1.5">
        {steps.map((step, index) => (
          <motion.li
            key={`${index}-${step.content}`}
            initial={{ opacity: 0, x: -6 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ duration: 0.2, delay: index * 0.03 }}
            className={cn(
              "flex items-start gap-2 text-[12px] leading-snug transition-colors duration-300",
              step.status === "completed"
                ? "text-text-muted line-through decoration-text-muted/40"
                : step.status === "in_progress"
                  ? "font-medium text-text"
                  : "text-text-secondary",
            )}
          >
            {step.status === "completed" ? (
              <CheckCircle2 size={13} className="mt-0.5 shrink-0 text-success" />
            ) : step.status === "in_progress" && working ? (
              <Loader2 size={13} className="mt-0.5 shrink-0 animate-spin text-info" />
            ) : (
              <Circle size={13} className="mt-0.5 shrink-0 text-text-muted/50" />
            )}
            {step.content}
          </motion.li>
        ))}
      </ul>
    </div>
  );
}

function Section({
  title,
  count,
  icon,
  children,
  defaultOpen = true,
}: {
  title: string;
  count?: number;
  icon?: React.ReactNode;
  children: React.ReactNode;
  defaultOpen?: boolean;
}) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div>
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="flex w-full items-center gap-1.5 py-1.5 text-left mk-focus-ring"
      >
        {open ? (
          <ChevronDown size={12} className="text-text-muted" />
        ) : (
          <ChevronRight size={12} className="text-text-muted" />
        )}
        {icon}
        <span className="text-[11px] font-semibold uppercase tracking-wider text-text-muted">
          {title}
        </span>
        {count != null && (
          <span className="ml-auto rounded-full bg-surface-raised px-1.5 py-0.5 text-[10px] tabular-nums text-text-muted">
            {count}
          </span>
        )}
      </button>
      {open && <div className="mt-2">{children}</div>}
    </div>
  );
}

function FileRow({ file }: { file: TaskAttachment }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(false);
  const [saveOpen, setSaveOpen] = useState(false);
  const isImage = file.mime_type?.startsWith("image/") ?? false;
  const isHtml =
    file.mime_type === "text/html" ||
    file.name.toLowerCase().endsWith(".html") ||
    file.name.toLowerCase().endsWith(".htm");
  const isPdf =
    file.mime_type === "application/pdf" || file.name.toLowerCase().endsWith(".pdf");
  const isMarkdown =
    file.mime_type === "text/markdown" || file.name.toLowerCase().endsWith(".md");
  const isText = !isHtml && !isMarkdown && isTextPreviewable(file.name, file.mime_type);
  const [blobUrl, setBlobUrl] = useState<string | null>(null);
  const [previewText, setPreviewText] = useState<string | null>(null);
  const [previewOpen, setPreviewOpen] = useState(false);

  // File bytes come through the authenticated API (same origin), never from
  // the object store directly — browsers may not be able to reach it.
  // Images are fetched eagerly for the inline preview.
  useEffect(() => {
    if (!isImage) return;
    let alive = true;
    let url: string | null = null;
    fetchDriveFileBlob(file.id)
      .then((blob) => {
        url = URL.createObjectURL(blob);
        if (alive) setBlobUrl(url);
        else URL.revokeObjectURL(url);
      })
      .catch(() => {
        if (alive) setError(true);
      });
    return () => {
      alive = false;
      if (url) URL.revokeObjectURL(url);
    };
  }, [file.id, isImage]);

  const ensureBlobUrl = async (): Promise<string> => {
    if (blobUrl) return blobUrl;
    const blob = await fetchDriveFileBlob(file.id);
    const url = URL.createObjectURL(blob);
    setBlobUrl(url);
    return url;
  };

  // Save-as via a same-origin blob anchor: no new tab, no popup blockers.
  const download = async (e?: React.MouseEvent) => {
    e?.stopPropagation();
    setBusy(true);
    setError(false);
    try {
      const url = await ensureBlobUrl();
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = file.name;
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
    } catch {
      setError(true);
    } finally {
      setBusy(false);
    }
  };

  const togglePreview = async (e?: React.MouseEvent) => {
    e?.stopPropagation();
    if (previewOpen) {
      setPreviewOpen(false);
      return;
    }
    if (previewText == null) {
      setBusy(true);
      try {
        const blob = await fetchDriveFileBlob(file.id);
        const text = await blob.text();
        setPreviewText(text.slice(0, 6000));
      } catch {
        setError(true);
        setBusy(false);
        return;
      }
      setBusy(false);
    }
    setPreviewOpen(true);
  };

  // Row click: rich deliverables (PDF / image / website / markdown) open in
  // the immersive viewer; plain text expands inline; other files download.
  const open = async () => {
    if (isPdf || isImage || isHtml || isMarkdown) {
      openDeliverable({ id: file.id, name: file.name, mime_type: file.mime_type });
      return;
    }
    if (isText) {
      void togglePreview();
      return;
    }
    void download();
  };

  return (
    <div className="overflow-hidden rounded-xl bg-surface-raised/60">
      <div className="group flex w-full items-center gap-2.5 px-3.5 py-2.5">
        <button
          type="button"
          onClick={open}
          disabled={busy}
          className="flex min-w-0 flex-1 items-center gap-2.5 text-left mk-focus-ring"
        >
          <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary-muted/40 text-primary-light">
            {fileIcon(file.mime_type)}
          </span>
          <span className="min-w-0 flex-1">
            <span className="block truncate text-xs font-medium text-text">
              {isHtml ? `🌐 ${file.name}` : file.name}
            </span>
            <span className="text-[10px] text-text-muted">
              {error
                ? "Could not load the file — tap to retry"
                : isHtml
                  ? "Open website preview"
                  : `${file.size_bytes ? formatBytes(file.size_bytes) : "·"} · ${formatDateTime(file.inserted_at)}`}
            </span>
          </span>
        </button>
        {busy ? (
          <Loader2 size={13} className="shrink-0 animate-spin text-text-muted" />
        ) : error ? (
          <AlertTriangle size={13} className="shrink-0 text-danger" />
        ) : (
          <span className="flex shrink-0 items-center gap-0.5">
            {isText && (
              <button
                type="button"
                onClick={togglePreview}
                aria-label={previewOpen ? `Hide preview of ${file.name}` : `Preview ${file.name}`}
                title={previewOpen ? "Hide preview" : "Preview content"}
                className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-surface-raised hover:text-text mk-focus-ring"
              >
                {previewOpen ? <EyeOff size={13} /> : <Eye size={13} />}
              </button>
            )}
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation();
                setSaveOpen(true);
              }}
              aria-label={`Save ${file.name} to Drive`}
              title="Save to Drive folder"
              className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-surface-raised hover:text-text mk-focus-ring"
            >
              <FolderInput size={13} />
            </button>
            <button
              type="button"
              onClick={download}
              aria-label={`Download ${file.name}`}
              title="Download locally"
              className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-surface-raised hover:text-text mk-focus-ring"
            >
              <Download size={13} />
            </button>
          </span>
        )}
      </div>
      <SaveToDriveModal
        open={saveOpen}
        onOpenChange={setSaveOpen}
        itemIds={[file.id]}
        itemLabel={file.name}
      />
      {previewOpen && previewText != null && (
        <div className="border-t border-border/50 bg-bg-deep/40 px-3.5 py-2.5">
          <pre className="max-h-56 overflow-auto whitespace-pre-wrap break-words text-[11px] leading-relaxed text-text-muted">
            {previewText}
            {previewText.length >= 6000 && "\n… (truncated — download for the full file)"}
          </pre>
        </div>
      )}
          {isImage && blobUrl && (
        <button
          type="button"
          onClick={open}
          className="block w-full bg-bg-deep/40 px-3.5 pb-3 pt-1 mk-focus-ring"
          aria-label={`Open ${file.name} full size`}
          title="Open full size"
        >
          <img
            src={blobUrl}
            alt={file.name}
            className="max-h-44 w-full rounded-lg object-contain"
            onError={() => setBlobUrl(null)}
          />
        </button>
      )}
      {isHtml && (
        <div className="border-t border-border/40 px-2.5 py-2.5">
          <DeployActions
            fileName={file.name}
            onPreview={() =>
              openDeliverable({ id: file.id, name: file.name, mime_type: file.mime_type })
            }
          />
        </div>
      )}
    </div>
  );
}

function MetaRow({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-center justify-between gap-3 py-2">
      <span className="shrink-0 text-[11px] text-text-muted">{label}</span>
      <div className="min-w-0">{children}</div>
    </div>
  );
}

export function TaskDetailPanel({
  taskId,
  onClose,
  overlay = false,
}: {
  taskId: string | null;
  onClose: () => void;
  overlay?: boolean;
}) {
  const [expandedDoc, setExpandedDoc] = useState<number | null>(0);

  const { data: taskData, isLoading } = useTask(taskId);
  const { data: agentsData } = useAgents();
  const { data: projectsData } = useProjects();
  const toggleSubtask = useToggleSubtask();
  const updateTask = useUpdateTask();
  const approveAction = useApproveTaskAction();
  const executeAi = useExecuteAi();
  const stopAi = useStopTaskAi();
  const deleteTask = useDeleteTask();
  const attachFile = useAttachTaskFile();
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const openChat = useChatStore((s) => s.openChat);

  const task = taskData?.data ?? null;
  const agents = agentsData?.data ?? [];
  const projects = projectsData?.data ?? [];

  const editable = useMemo(() => {
    if (!task) return false;
    if (["completed", "canceled"].includes(task.status)) return false;
    if (task.due_at && new Date(task.due_at).getTime() < Date.now()) return false;
    return true;
  }, [task]);

  const outputs = task?.attachments.filter((f) => f.source === "output") ?? [];
  const inputs = task?.attachments.filter((f) => f.source === "input") ?? [];
  const run = task?.latest_run ?? null;
  const docs = useMemo(() => producedDocs(run?.output?.tool_calls ?? []), [run]);
  // Live plan (streamed via channel) wins over the last persisted snapshot.
  const livePlan = useMissionPlanStore((s) => (taskId ? s.plans[taskId] : undefined));
  const plan = livePlan ?? run?.plan ?? [];
  const pendingApproval = task?.pending_approval ?? null;
  const waitingApproval = run?.status === "waiting_for_approval" || pendingApproval != null;
  const agentWorking =
    !waitingApproval && run != null && ["queued", "running"].includes(run.status);
  const runFailed = run?.status === "failed" && task?.status !== "completed";
  const canRetry =
    task != null && !["completed", "canceled"].includes(task.status) && !agentWorking;

  const chatAgentId = task?.chat_agent_id ?? task?.assigned_agent_id;
  const canOpenConversation =
    chatAgentId != null && task?.assigned_agent_kind !== "human_linked";

  // Immersive delivery: when the mission just finished (fresh completion),
  // open the newest deliverable in the full viewer so the user sees the
  // result immediately. Old tasks reopened later don't hijack the screen.
  const autoOpenedRunRef = useRef<string | null>(null);
  useEffect(() => {
    if (!run || run.status !== "completed" || outputs.length === 0) return;
    if (autoOpenedRunRef.current === run.id) return;
    autoOpenedRunRef.current = run.id;

    const completedAt = run.completed_at ? new Date(run.completed_at).getTime() : 0;
    if (Date.now() - completedAt > 2 * 60 * 1000) return;

    const newest = [...outputs].sort(
      (a, b) => new Date(a.inserted_at).getTime() - new Date(b.inserted_at).getTime(),
    )[outputs.length - 1];
    openDeliverable({ id: newest.id, name: newest.name, mime_type: newest.mime_type });
  }, [run, outputs]);

  const openTaskConversation = () => {
    if (!chatAgentId) return;
    openChat(chatAgentId, task?.conversation_id ?? null);
  };

  const decide = (decision: "approved" | "rejected") => {
    if (!task || !pendingApproval) return;
    approveAction.mutate({
      taskId: task.id,
      approvalRequestId: pendingApproval.id,
      decision,
    });
  };

  const chooseSiteDelivery = (delivery: "html" | "webapp") => {
    if (!task || !pendingApproval) return;
    approveAction.mutate({
      taskId: task.id,
      approvalRequestId: pendingApproval.id,
      decision: "edited",
      payload: { delivery },
    });
  };

  const siteDeliveryPayload = isSiteDeliveryChoice(pendingApproval?.input_payload)
    ? pendingApproval.input_payload
    : null;

  const retry = () => {
    if (!task) return;
    executeAi.mutate({ taskId: task.id });
  };

  const onFilesPicked = (files: FileList | null) => {
    if (!task || !files) return;
    Array.from(files).forEach((file) => attachFile.mutate({ file, taskId: task.id }));
    if (fileInputRef.current) fileInputRef.current.value = "";
  };

  const patch = (body: Record<string, unknown>) => {
    if (!task) return;
    updateTask.mutate({ id: task.id, ...body });
  };

  return (
    <DetailPanel open={taskId != null} onClose={onClose} title="Task Details" overlay={overlay}>
      {isLoading && (
        <div className="flex items-center justify-center py-16 text-text-muted">
          <Loader2 size={18} className="animate-spin" />
        </div>
      )}

      {task && (
        <div className="flex flex-col gap-5 px-5 pb-5 pt-2">
          {/* Header */}
          <div>
            <h3 className="text-[15px] font-bold leading-snug text-text">{task.title}</h3>
            {task.description && (
              <p className="mt-1.5 text-[12px] leading-relaxed text-text-secondary">
                {task.description}
              </p>
            )}
            <div className="mt-3 flex flex-wrap items-center gap-1.5">
              <TaskStatusBadge status={task.status} />
              <PriorityBadge priority={task.priority} />
              {task.tags.map((tag) => (
                <Badge key={tag} tone="muted">{tag}</Badge>
              ))}
            </div>
          </div>

          {/* Persistent out-of-specialty note from dispatch time. */}
          {task.capability_match?.warning_shown &&
            task.assigned_agent_id &&
            !["completed", "canceled"].includes(task.status) && (
              <div className="flex items-start gap-2.5 rounded-xl border border-warning/30 bg-warning/8 px-3.5 py-2.5">
                <AlertTriangle size={13} className="mt-0.5 shrink-0 text-warning" />
                <p className="min-w-0 flex-1 text-[11px] leading-snug text-text-secondary">
                  <span className="font-semibold text-text">
                    {task.assigned_agent_name ?? "The assigned agent"}
                  </span>{" "}
                  isn’t specialized in this
                  {task.domain_requested.length > 0
                    ? ` (${task.domain_requested.join(", ")})`
                    : ""}{" "}
                  work — the result may be limited.
                </p>
              </div>
            )}

          {/* Composite multi-agent plan — children run in waves with handoffs. */}
          {task.composite && !["completed", "canceled"].includes(task.status) && (
            <div className="rounded-xl bg-info/8 px-3.5 py-3">
              <p className="text-[12px] font-semibold text-text">
                Multi-agent mission
              </p>
              <p className="mt-0.5 text-[11px] leading-snug text-text-secondary">
                Split into {task.composite.total} specialist workstreams (wave{" "}
                {task.composite.current_wave}). Deliverables hand off between waves
                automatically — track them in the checklist below.
              </p>
              <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-surface-raised">
                <div
                  className="h-full rounded-full bg-info transition-all"
                  style={{ width: `${task.progress_percent}%` }}
                />
              </div>
            </div>
          )}
          {task.composite_parent_id && (
            <div className="rounded-xl bg-surface-raised/50 px-3.5 py-2.5">
              <p className="text-[11px] leading-snug text-text-secondary">
                Part of a multi-agent mission — this agent owns one workstream.
              </p>
            </div>
          )}

          {/* Status banners */}
          {agentWorking && (
            <div className="flex items-center gap-3 rounded-xl bg-info/8 px-4 py-3.5">
              <div className="relative flex items-center justify-center">
                <span className="absolute inline-flex h-5 w-5 animate-ping rounded-full bg-info/30" />
                <Loader2 size={16} className="relative animate-spin text-info" />
              </div>
              <p className="min-w-0 flex-1 text-[12px] leading-snug text-text-secondary">
                <span className="font-semibold text-text">
                  {task.assigned_agent_name ?? "Agent"}
                </span>{" "}
                {run?.status === "queued" ? "is queued…" : "is working…"}
              </p>
              <Button
                size="sm"
                variant="danger"
                className="shrink-0 gap-1.5"
                loading={stopAi.isPending}
                onClick={() => stopAi.mutate(task.id)}
              >
                <Square size={11} /> Stop
              </Button>
            </div>
          )}

          {/* Live mission checklist (deep-agent todos, streamed in realtime). */}
          {plan.length > 0 && (agentWorking || waitingApproval || run?.status === "completed") && (
            <MissionPlan steps={plan} working={agentWorking} />
          )}

          {/* Idle to_do task with an AI agent: one click to launch. */}
          {task.status === "to_do" && task.assigned_agent_id && !agentWorking && !waitingApproval && (
            <Button
              className="w-full gap-1.5"
              loading={executeAi.isPending}
              onClick={retry}
            >
              <Play size={13} /> Start the mission with {task.assigned_agent_name ?? "the agent"}
            </Button>
          )}

          {/* Approval needed: the agent paused and waits for a human decision. */}
          {waitingApproval && pendingApproval && (
            <div className="rounded-xl bg-warning/10 px-4 py-3.5">
              <div className="flex items-start gap-2.5">
                <ShieldAlert size={15} className="mt-0.5 shrink-0 text-warning" />
                <div className="min-w-0 flex-1">
                  <p className="text-[12px] font-semibold text-text">
                    {siteDeliveryPayload
                      ? "How should we deliver this site?"
                      : `${task.assigned_agent_name ?? "The agent"} needs your approval`}
                  </p>
                  <p className="mt-0.5 text-[11px] leading-snug text-text-secondary">
                    {pendingApproval.proposed_action}
                  </p>
                  {!siteDeliveryPayload && (
                    <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
                      <Badge tone="muted">{pendingApproval.tool_name}</Badge>
                      <span
                        className={
                          "rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide " +
                          (["high", "critical"].includes(pendingApproval.risk_level)
                            ? "bg-danger/15 text-danger"
                            : "bg-warning/15 text-warning")
                        }
                      >
                        {pendingApproval.risk_level} risk
                      </span>
                    </div>
                  )}
                </div>
              </div>
              {siteDeliveryPayload ? (
                <div className="mt-3">
                  <SiteDeliveryChoice
                    payload={siteDeliveryPayload}
                    busy={approveAction.isPending}
                    onChoose={chooseSiteDelivery}
                  />
                </div>
              ) : (
                <div className="mt-3 flex gap-2">
                  <Button
                    size="sm"
                    className="flex-1 gap-1.5"
                    loading={approveAction.isPending}
                    onClick={() => decide("approved")}
                  >
                    <ThumbsUp size={12} /> Approve
                  </Button>
                  <Button
                    size="sm"
                    variant="secondary"
                    className="flex-1 gap-1.5"
                    disabled={approveAction.isPending}
                    onClick={() => decide("rejected")}
                  >
                    <ThumbsDown size={12} /> Reject
                  </Button>
                </div>
              )}
            </div>
          )}

          {/* Orphaned wait: the run says "waiting" but no approval exists to
              decide on (e.g. worker restarted). Offer a clean restart. */}
          {waitingApproval && !pendingApproval && (
            <div className="rounded-xl bg-warning/10 px-4 py-3.5">
              <div className="flex items-start gap-2.5">
                <AlertTriangle size={15} className="mt-0.5 shrink-0 text-warning" />
                <div>
                  <p className="text-[12px] font-semibold text-text">
                    The agent is stuck waiting
                  </p>
                  <p className="mt-0.5 text-[11px] leading-snug text-text-secondary">
                    Its approval request could not be found. Restart the mission to continue.
                  </p>
                </div>
              </div>
              <Button
                size="sm"
                className="mt-3 w-full gap-1.5"
                loading={executeAi.isPending}
                onClick={retry}
              >
                <RefreshCw size={12} /> Restart mission
              </Button>
            </div>
          )}

          {task.status === "in_review" && !agentWorking && (
            <div className="rounded-xl bg-primary/8 px-4 py-3.5">
              <div className="flex items-center gap-2.5">
                <Sparkles size={15} className="shrink-0 text-primary" />
                <p className="text-[12px] leading-snug text-text-secondary">
                  <span className="font-semibold text-text">Ready for review</span>. Check the
                  output below.
                </p>
              </div>
              <div className="mt-3 flex gap-2">
                <Button
                  size="sm"
                  className="flex-1 gap-1.5"
                  loading={updateTask.isPending}
                  onClick={() => patch({ status: "completed" })}
                >
                  <ThumbsUp size={12} /> Approve
                </Button>
                <Button
                  size="sm"
                  variant="secondary"
                  className="flex-1 gap-1.5"
                  onClick={() => patch({ status: "in_progress" })}
                >
                  <Undo2 size={12} /> Revise
                </Button>
              </div>
            </div>
          )}

          {runFailed && !waitingApproval && (
            <div className="rounded-xl bg-danger/8 px-4 py-3.5">
              <div className="flex items-start gap-2.5">
                <AlertTriangle size={15} className="mt-0.5 shrink-0 text-danger" />
                <div>
                  <p className="text-[12px] font-semibold text-danger">Run failed</p>
                  <p className="mt-0.5 text-[11px] leading-snug text-text-secondary">
                    {humanizeErrorMessage(run?.error) || "An unexpected error occurred."}
                  </p>
                </div>
              </div>
              {canRetry && (
                <Button
                  size="sm"
                  variant="secondary"
                  className="mt-3 w-full gap-1.5"
                  loading={executeAi.isPending}
                  onClick={retry}
                >
                  <RefreshCw size={12} /> Retry mission
                </Button>
              )}
            </div>
          )}

          {/* Metadata */}
          <div className="rounded-xl bg-surface-raised/40 px-4 py-1">
            <MetaRow label="Agent">
              {editable ? (
                <Select
                  className="h-7 w-full text-[11px]"
                  value={task.assigned_agent_id ?? NO_AGENT}
                  onValueChange={(v) => {
                    const nextId = v === NO_AGENT ? null : v;
                    patch({ assigned_agent_id: nextId });
                    // Soft capability check — inform, never block.
                    if (nextId) {
                      const agent = agents.find((a) => a.id === nextId);
                      if (agent && !agentCoversDomains(agent, task.domain_requested)) {
                        toast({
                          tone: "warning",
                          title: `${agent.display_name} isn't specialized in ${task.domain_requested.join(", ")}`,
                          description:
                            "They'll do their best, but the result may be limited. Consider a dedicated specialist for this domain.",
                        });
                      }
                    }
                  }}
                  options={[
                    { value: NO_AGENT, label: "Unassigned" },
                    ...agents.map((a) => ({ value: a.id, label: a.display_name })),
                  ]}
                />
              ) : (
                <span className="flex items-center gap-1.5 text-xs text-text">
                  <Avatar
                    name={task.assigned_agent_name}
                    size="xs"
                    isAi={task.assigned_agent_kind === "ai"}
                  />
                  {task.assigned_agent_name ?? "Unassigned"}
                </span>
              )}
            </MetaRow>

            <MetaRow label="Project">
              {editable ? (
                <Select
                  className="h-7 w-full text-[11px]"
                  value={task.project_id ?? NO_PROJECT}
                  onValueChange={(v) =>
                    patch({ project_id: v === NO_PROJECT ? null : v })
                  }
                  options={[
                    { value: NO_PROJECT, label: "No project" },
                    ...projects.map((p) => ({ value: p.id, label: p.name })),
                  ]}
                />
              ) : (
                <span className="text-xs text-text">{task.project_name ?? "None"}</span>
              )}
            </MetaRow>

            <MetaRow label="Due">
              {editable ? (
                <input
                  type="datetime-local"
                  className="mk-input h-7 w-full text-[11px]"
                  value={toDatetimeLocal(task.due_at)}
                  onChange={(e) =>
                    patch({
                      due_at: e.target.value ? new Date(e.target.value).toISOString() : null,
                    })
                  }
                />
              ) : (
                <span className="flex items-center gap-1.5 text-xs text-text">
                  <Clock size={12} className="text-text-muted" />
                  {task.due_at ? formatDateTime(task.due_at) : "None"}
                </span>
              )}
            </MetaRow>

            <MetaRow label="Created">
              <span className="text-xs text-text-muted">{formatDateTime(task.inserted_at)}</span>
            </MetaRow>

            {/* User-facing cost: credits only — provider cost stays in the CRM. */}
            {run != null && run.credits_charged > 0 && (
              <MetaRow label="Cost">
                <span className="flex items-center gap-1.5 text-xs font-medium text-text">
                  <Sparkles size={11} className="text-primary-light" />
                  {run.credits_charged} credit{run.credits_charged > 1 ? "s" : ""}
                  {run.token_usage?.total_tokens ? (
                    <span className="font-normal text-text-muted">
                      · {formatTokens(run.token_usage.total_tokens)} tokens
                    </span>
                  ) : null}
                </span>
              </MetaRow>
            )}
          </div>

          {/* Progress */}
          {task.progress_percent > 0 && task.status !== "completed" && (
            <div className="rounded-xl bg-surface-raised/40 px-4 py-3">
              <div className="mb-2 flex justify-between text-[11px]">
                <span className="text-text-muted">Progress</span>
                <span className="font-bold tabular-nums text-text">
                  {task.progress_percent}%
                </span>
              </div>
              <div className="h-1.5 overflow-hidden rounded-full bg-surface-raised">
                <div
                  className="h-full rounded-full bg-primary transition-all"
                  style={{ width: `${task.progress_percent}%` }}
                />
              </div>
            </div>
          )}

          {/* Output */}
          {(outputs.length > 0 || docs.length > 0) && (
            <Section
              title="Output"
              count={outputs.length + docs.length}
              icon={<Sparkles size={11} className="text-primary" />}
            >
              <div className="space-y-2">
                <CodebaseCard
                  files={outputs}
                  toolOutput={
                    run?.output?.tool_calls?.find((c) => c.tool === "generate_webapp")?.output as
                      | Record<string, unknown>
                      | undefined
                  }
                />
                {outputs.map((f) => (
                  <FileRow key={f.id} file={f} />
                ))}
                {docs.map((doc, i) => (
                  <div key={i} className="overflow-hidden rounded-xl bg-surface-raised/60">
                    <button
                      type="button"
                      onClick={() => setExpandedDoc(expandedDoc === i ? null : i)}
                      className="flex w-full items-center gap-2 px-3.5 py-2.5 text-left transition-colors hover:bg-surface-hover mk-focus-ring"
                    >
                      <FileText size={13} className="shrink-0 text-primary" />
                      <span className="min-w-0 flex-1 truncate text-xs font-medium text-text">
                        {doc.title}
                      </span>
                      <span className="rounded-md bg-surface-raised px-2 py-0.5 text-[10px] text-text-muted">
                        {expandedDoc === i ? "Hide" : "View"}
                      </span>
                    </button>
                    {expandedDoc === i && (
                      <div className="border-t border-border/50 bg-bg-deep/50 px-3.5 py-3">
                        <div className="mb-2 flex justify-end">
                          <button
                            type="button"
                            onClick={() => {
                              void navigator.clipboard.writeText(doc.content);
                              toast({ tone: "success", title: "Copied", description: doc.title });
                            }}
                            className="flex items-center gap-1 rounded-md px-2 py-1 text-[10px] text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
                          >
                            <Copy size={11} /> Copy
                          </button>
                        </div>
                        <div className="max-h-64 overflow-y-auto">
                          <MarkdownView markdown={doc.content} />
                        </div>
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </Section>
          )}

          {/* Attachments — always visible so users can hand the agent new
              material (e.g. a usable file format) at any point. */}
          <Section
            title="Attachments"
            count={inputs.length}
            icon={<Paperclip size={11} className="text-text-muted" />}
          >
            <div className="space-y-2">
              {inputs.map((f) => (
                <FileRow key={f.id} file={f} />
              ))}
              <input
                ref={fileInputRef}
                type="file"
                multiple
                className="hidden"
                onChange={(e) => onFilesPicked(e.target.files)}
              />
              <button
                type="button"
                onClick={() => fileInputRef.current?.click()}
                disabled={attachFile.isPending}
                className="flex w-full items-center justify-center gap-2 rounded-xl border border-dashed border-border px-3.5 py-2.5 text-[11px] font-medium text-text-muted transition-colors hover:border-primary/50 hover:text-text mk-focus-ring"
              >
                {attachFile.isPending ? (
                  <Loader2 size={12} className="animate-spin" />
                ) : (
                  <Paperclip size={12} />
                )}
                Add a file for {task.assigned_agent_name ?? "the agent"}
              </button>
            </div>
          </Section>

          {/* Subtasks */}
          {task.subtasks.length > 0 && (
            <Section
              title="Subtasks"
              count={task.subtask_done_count}
              icon={<CheckCircle2 size={11} className="text-text-muted" />}
            >
              <div className="space-y-0.5">
                {task.subtasks
                  .slice()
                  .sort((a, b) => a.position - b.position)
                  .map((st) => (
                    <button
                      key={st.id}
                      type="button"
                      onClick={() =>
                        toggleSubtask.mutate({
                          taskId: task.id,
                          subtaskId: st.id,
                          done: !st.done,
                        })
                      }
                      className="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-xs transition-colors hover:bg-surface-hover mk-focus-ring"
                    >
                      {st.done ? (
                        <CheckCircle2 size={14} className="shrink-0 text-success" />
                      ) : (
                        <Circle size={14} className="shrink-0 text-text-muted/50" />
                      )}
                      <span className={st.done ? "text-text-muted line-through" : "text-text"}>
                        {st.title}
                      </span>
                    </button>
                  ))}
              </div>
            </Section>
          )}

          {/* Conversation lives in the floating agent chat bubble. */}
          {canOpenConversation && (
            <Button
              variant="secondary"
              size="sm"
              className="w-full gap-1.5"
              onClick={openTaskConversation}
            >
              <MessageCircle size={12} />
              Voir conversation
            </Button>
          )}

          {/* Danger zone — deleting also aborts the agent's run and frees it
              for its next queued mission. */}
          <button
            type="button"
            onClick={() => {
              if (window.confirm(`Delete "${task.title}"? The agent will stop working on it.`)) {
                deleteTask.mutate(task.id, { onSuccess: onClose });
              }
            }}
            disabled={deleteTask.isPending}
            className="flex w-full items-center justify-center gap-2 rounded-xl border border-danger/20 py-2.5 text-xs font-medium text-danger transition-colors hover:bg-danger/10 mk-focus-ring"
          >
            <Trash2 size={13} /> Delete task
          </button>
        </div>
      )}
    </DetailPanel>
  );
}
