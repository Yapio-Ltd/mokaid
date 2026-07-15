import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowRight,
  Check,
  CheckCircle2,
  Loader2,
  Plug,
  Sparkles,
  Wand2,
} from "lucide-react";
import { useNavigate } from "@tanstack/react-router";
import {
  useAgents,
  useDispatchAnalyze,
  useDispatchConfirm,
  useInstallMcp,
  useUploadDriveFile,
} from "@/api/hooks";
import type { Agent, DispatchAnalysis, DispatchFileInput, DriveItem } from "@/api/types";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Textarea } from "@/components/ui/textarea";
import { useAuthStore } from "@/stores/auth-store";
import { useActiveProjectId, useProjectStore } from "@/stores/project-store";
import { useUiStore } from "@/stores/ui-store";
import { cn } from "@/lib/cn";
import { parserForFile } from "@/lib/file-parsers";
import { fileIcon, formatFileSize } from "@/lib/file-ui";

type Step = "describe" | "recommend" | "done" | "analyzing";

function ConfidenceBar({ value }: { value: number }) {
  return (
    <span className="flex items-center gap-1.5">
      <span className="h-1.5 w-16 overflow-hidden rounded-full bg-surface-overlay">
        <span
          className={cn(
            "block h-full rounded-full transition-all",
            value >= 70 ? "bg-success" : value >= 45 ? "bg-warning" : "bg-danger",
          )}
          style={{ width: `${value}%` }}
        />
      </span>
      <span className="text-[10px] font-semibold text-text-muted">{value}%</span>
    </span>
  );
}

function AgentChoiceCard({
  agent,
  confidence,
  reason,
  selected,
  onSelect,
  badge,
}: {
  agent: Agent;
  confidence: number;
  reason?: string;
  selected: boolean;
  onSelect: () => void;
  badge?: string;
}) {
  return (
    <button
      onClick={onSelect}
      className={cn(
        "flex w-full items-start gap-3 rounded-lg border p-3 text-left transition-all mk-focus-ring",
        selected
          ? "border-primary/60 bg-primary-muted/40 shadow-glow"
          : "border-border bg-surface-raised hover:border-border-strong hover:bg-surface-hover",
      )}
    >
      <Avatar
        name={agent.display_name}
        size="md"
        isAi={agent.kind === "ai"}
        color={agent.avatar_config?.primary_color}
      />
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-2">
          <span className="truncate text-xs font-semibold text-text">{agent.display_name}</span>
          {badge && (
            <span className="rounded-full bg-primary/15 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-wide text-primary-light">
              {badge}
            </span>
          )}
        </span>
        <span className="mt-0.5 block truncate text-[11px] text-text-muted">
          {agent.role_title ?? agent.department ?? "Agent"}
        </span>
        {reason && <span className="mt-1.5 block text-[11px] leading-snug text-text-secondary">{reason}</span>}
        <span className="mt-1.5 block">
          <ConfidenceBar value={confidence} />
        </span>
      </span>
      <span
        className={cn(
          "mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center rounded-full border",
          selected ? "border-primary bg-primary text-white" : "border-border-strong",
        )}
      >
        {selected && <Check size={10} strokeWidth={3} />}
      </span>
    </button>
  );
}

export function DropDispatchModal({
  open,
  onOpenChange,
  files,
  initialInstruction = "",
  autoAnalyze = false,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  files: File[];
  /** Prefill the instruction textarea (e.g. from the dashboard Ask bar). */
  initialInstruction?: string;
  /** Skip the describe step and run analysis as soon as the modal opens. */
  autoAnalyze?: boolean;
}) {
  const navigate = useNavigate();
  const { data: agentsData } = useAgents();
  const uploadFile = useUploadDriveFile();
  const analyze = useDispatchAnalyze();
  const confirm = useDispatchConfirm();
  const installMcp = useInstallMcp();

  // The task lands in the project currently selected in the header, so it is
  // immediately visible in the pipeline the user is looking at.
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const activeProjectId = useActiveProjectId(workspaceId);
  const setActiveProject = useProjectStore((s) => s.setActiveProject);
  const selectTask = useUiStore((s) => s.selectTask);

  const [step, setStep] = useState<Step>("describe");
  const [instruction, setInstruction] = useState("");
  const [uploaded, setUploaded] = useState<DriveItem[]>([]);
  const [analysis, setAnalysis] = useState<DispatchAnalysis | null>(null);
  const [selection, setSelection] = useState<{ kind: "agent"; agentId: string } | { kind: "custom" } | null>(null);
  const [grantIds, setGrantIds] = useState<Set<string>>(new Set());
  const [mcpKeys, setMcpKeys] = useState<Record<string, string>>({});
  const [connectedNow, setConnectedNow] = useState<Record<string, string>>({});
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{
    agentName: string | null;
    agentCreated: boolean;
    taskTitle: string;
    taskId: string;
    projectId: string | null;
  } | null>(null);

  const agents = useMemo(() => agentsData?.data ?? [], [agentsData]);
  const agentById = useMemo(() => new Map(agents.map((a) => [a.id, a])), [agents]);

  // Guard so we only auto-analyze once per open cycle.
  const autoStarted = useRef(false);

  const busy = uploadFile.isPending || analyze.isPending || step === "analyzing";

  const handleAnalyze = useCallback(async (instructionOverride?: string, options?: { fresh?: boolean }) => {
    const text = instructionOverride ?? instruction;
    setError(null);
    setStep("analyzing");
    try {
      // Upload once; re-analyzing after edits reuses the same drive items.
      // `fresh` clears any leftovers from a previous open cycle (Ask bar / drop).
      let items = options?.fresh ? [] : uploaded;
      if (items.length === 0 && files.length > 0) {
        items = await Promise.all(files.map((file) => uploadFile.mutateAsync({ file, parentId: null }).then((r) => r.data)));
        setUploaded(items);
      }

      const filesPayload: DispatchFileInput[] = items.map((item) => ({
        drive_item_id: item.id,
        name: item.name,
        mime_type: item.mime_type,
        size_bytes: item.size_bytes,
      }));

      const response = await analyze.mutateAsync({ instruction: text, files: filesPayload });
      const data = response.data;
      setAnalysis(data);

      if (data.recommendation.mode === "custom_agent") {
        setSelection({ kind: "custom" });
      } else if (data.recommendation.agent_id) {
        setSelection({ kind: "agent", agentId: data.recommendation.agent_id });
      }
      // Pre-check grants that only need authorization.
      setGrantIds(
        new Set(
          data.mcp_suggestions
            .filter((s) => s.status === "needs_grant" && s.installation_id)
            .map((s) => s.installation_id as string),
        ),
      );
      setStep("recommend");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Analysis failed, please retry.");
      setStep("describe");
    }
  }, [instruction, uploaded, files, uploadFile, analyze]);

  // Fresh open = fresh flow. Prefill + optionally auto-analyze.
  useEffect(() => {
    if (!open) {
      autoStarted.current = false;
      return;
    }

    setUploaded([]);
    setAnalysis(null);
    setSelection(null);
    setGrantIds(new Set());
    setMcpKeys({});
    setConnectedNow({});
    setError(null);
    setResult(null);
    setInstruction(initialInstruction);

    if (autoAnalyze && (initialInstruction.trim() || files.length > 0) && !autoStarted.current) {
      autoStarted.current = true;
      setStep("analyzing");
      void handleAnalyze(initialInstruction, { fresh: true });
    } else {
      setStep("describe");
    }
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps -- reset only on open/close

  const handleConnectMcp = async (serverKey: string) => {
    const key = mcpKeys[serverKey]?.trim();
    if (!key) return;
    try {
      const response = await installMcp.mutateAsync({ serverKey, credentials: { api_key: key } });
      setConnectedNow((prev) => ({ ...prev, [serverKey]: response.data.id }));
      setGrantIds((prev) => new Set(prev).add(response.data.id));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Connection failed.");
    }
  };

  const handleConfirm = async () => {
    if (!analysis || !selection) return;
    setError(null);
    try {
      const response = await confirm.mutateAsync({
        instruction,
        task: {
          title: analysis.task.title,
          description: analysis.task.description,
          priority: analysis.task.priority,
          project_id: activeProjectId ?? undefined,
        },
        ...(selection.kind === "agent"
          ? { agent_id: selection.agentId }
          : analysis.recommendation.custom_agent
            ? { custom_agent: analysis.recommendation.custom_agent }
            : {}),
        grant_installation_ids: [...grantIds],
        drive_item_ids: uploaded.map((item) => item.id),
        start_now: true,
      });
      setResult({
        agentName: response.data.agent?.display_name ?? null,
        agentCreated: selection.kind === "custom",
        taskTitle: response.data.task.title,
        taskId: response.data.task.id,
        projectId: response.data.task.project_id ?? null,
      });
      setStep("done");
    } catch (e) {
      setError(e instanceof Error ? e.message : "Could not create the task.");
    }
  };

  const recommendation = analysis?.recommendation;
  const recommendedAgent = recommendation?.agent_id ? agentById.get(recommendation.agent_id) : null;

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title={
        step === "describe"
          ? files.length > 0
            ? "What should we do with these files?"
            : "What should we do?"
          : step === "analyzing"
            ? "Analyzing request"
            : step === "recommend"
              ? "Smart assignment"
              : "Task dispatched"
      }
      description={
        step === "describe"
          ? "Describe what you need. The dispatcher will route it to the right agent."
          : step === "analyzing"
            ? files.length > 0
              ? "Uploading attachments and finding the best agent…"
              : "Finding the best agent for your request…"
            : step === "recommend"
              ? "Review the recommendation, then launch."
              : undefined
      }
      className="w-[540px]"
      footer={
        step === "describe" ? (
          <>
            <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
              Cancel
            </Button>
            <Button size="sm" loading={busy} disabled={!instruction.trim() && files.length === 0} onClick={() => void handleAnalyze()}>
              <Sparkles size={13} />
              Analyze request
            </Button>
          </>
        ) : step === "analyzing" ? (
          <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
        ) : step === "recommend" ? (
          <>
            <Button variant="ghost" size="sm" onClick={() => setStep("describe")}>
              Back
            </Button>
            <Button size="sm" loading={confirm.isPending} disabled={!selection} onClick={handleConfirm}>
              <ArrowRight size={13} />
              {selection?.kind === "custom" ? "Create agent & launch" : "Assign & launch"}
            </Button>
          </>
        ) : (
          <Button size="sm" onClick={() => onOpenChange(false)}>
            Done
          </Button>
        )
      }
    >
      {(step === "describe" || step === "analyzing") && (
        <div className="space-y-4">
          {files.length > 0 && (
            <div className="flex flex-wrap gap-2">
              {files.map((file, index) => {
                const Icon = fileIcon(file);
                const parser = parserForFile(file.name, file.type);
                return (
                  <span
                    key={`${file.name}-${index}`}
                    className="flex items-center gap-2 rounded-md border border-border bg-surface-raised px-2.5 py-1.5"
                    title={
                      parser.method === "native"
                        ? `Read natively by agents (${parser.label} parser)`
                        : parser.method === "ai"
                          ? `Processed with AI (${parser.label})`
                          : "Format not directly readable — agents will try AI vision"
                    }
                  >
                    <Icon size={14} className="text-primary-light" />
                    <span className="max-w-[160px] truncate text-[11px] font-medium text-text">{file.name}</span>
                    <span className="text-[10px] text-text-muted">{formatFileSize(file.size)}</span>
                    <span
                      className={cn(
                        "flex items-center gap-1 rounded-full px-1.5 py-0.5 text-[9px] font-semibold uppercase tracking-wide",
                        parser.method === "native"
                          ? "bg-success/15 text-success"
                          : parser.method === "ai"
                            ? "bg-info/15 text-info"
                            : "bg-warning/15 text-warning",
                      )}
                    >
                      {parser.method === "native" && <Check size={9} strokeWidth={3} />}
                      {parser.label}
                    </span>
                  </span>
                );
              })}
            </div>
          )}
          {step === "describe" && (
            <Textarea
              autoFocus
              placeholder="e.g. Turn these mockups into a landing page brief, extract the key numbers from this spreadsheet…"
              value={instruction}
              onChange={(e) => setInstruction(e.target.value)}
              className="min-h-[110px]"
            />
          )}
          {error && <p className="text-[11px] text-danger">{error}</p>}
          {busy && (
            <p className="flex items-center gap-2 text-[11px] text-text-muted">
              <Loader2 size={12} className="animate-spin" />
              {uploadFile.isPending ? "Uploading files…" : "The dispatcher is analyzing your request…"}
            </p>
          )}
        </div>
      )}

      {step === "recommend" && analysis && recommendation && (
        <div className="space-y-4">
          {/* Proposed task summary */}
          <div className="rounded-lg border border-border bg-surface-raised px-3 py-2.5">
            <p className="text-[10px] font-semibold uppercase tracking-widest text-text-muted">Task</p>
            <p className="mt-0.5 text-xs font-semibold text-text">{analysis.task.title}</p>
            <p className="mt-0.5 line-clamp-2 text-[11px] text-text-secondary">{analysis.task.description}</p>
          </div>

          {/* Dispatcher verdict */}
          <p className="flex items-start gap-2 text-[11px] leading-snug text-text-secondary">
            <Sparkles size={13} className="mt-0.5 shrink-0 text-primary-light" />
            {recommendation.reason}
          </p>

          <div className="space-y-2">
            {recommendedAgent && (
              <AgentChoiceCard
                agent={recommendedAgent}
                confidence={recommendation.confidence}
                selected={selection?.kind === "agent" && selection.agentId === recommendedAgent.id}
                onSelect={() => setSelection({ kind: "agent", agentId: recommendedAgent.id })}
                badge="Recommended"
              />
            )}

            {recommendation.custom_agent && (
              <button
                onClick={() => setSelection({ kind: "custom" })}
                className={cn(
                  "flex w-full items-start gap-3 rounded-lg border border-dashed p-3 text-left transition-all mk-focus-ring",
                  selection?.kind === "custom"
                    ? "border-primary/60 bg-primary-muted/40 shadow-glow"
                    : "border-border-strong bg-surface-raised hover:bg-surface-hover",
                )}
              >
                <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-primary-muted text-primary-light">
                  <Wand2 size={15} />
                </span>
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-2">
                    <span className="text-xs font-semibold text-text">
                      Create “{recommendation.custom_agent.display_name}”
                    </span>
                    <span className="rounded-full bg-info/15 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-wide text-info">
                      New agent
                    </span>
                  </span>
                  <span className="mt-0.5 block text-[11px] text-text-muted">
                    {recommendation.custom_agent.role_title ?? "Purpose-built specialist"}
                  </span>
                  <span className="mt-1.5 flex flex-wrap gap-1">
                    {recommendation.custom_agent.skills.map((skill) => (
                      <span
                        key={skill.name}
                        className="rounded bg-surface-overlay px-1.5 py-0.5 text-[10px] text-text-secondary"
                      >
                        {skill.name}
                      </span>
                    ))}
                  </span>
                </span>
                <span
                  className={cn(
                    "mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center rounded-full border",
                    selection?.kind === "custom" ? "border-primary bg-primary text-white" : "border-border-strong",
                  )}
                >
                  {selection?.kind === "custom" && <Check size={10} strokeWidth={3} />}
                </span>
              </button>
            )}

            {recommendation.alternatives.map((alt) => {
              const agent = agentById.get(alt.agent_id);
              if (!agent) return null;
              return (
                <AgentChoiceCard
                  key={alt.agent_id}
                  agent={agent}
                  confidence={alt.confidence}
                  reason={alt.reason}
                  selected={selection?.kind === "agent" && selection.agentId === alt.agent_id}
                  onSelect={() => setSelection({ kind: "agent", agentId: alt.agent_id })}
                />
              );
            })}
          </div>

          {/* MCP boosters */}
          {analysis.mcp_suggestions.length > 0 && (
            <div className="space-y-2">
              <p className="text-[10px] font-semibold uppercase tracking-widest text-text-muted">
                Go even faster
              </p>
              {analysis.mcp_suggestions.map((suggestion) => {
                const justConnected = connectedNow[suggestion.server_key];
                const effectiveStatus = justConnected ? "needs_grant" : suggestion.status;
                const grantId = justConnected ?? suggestion.installation_id;

                return (
                  <div
                    key={suggestion.server_key}
                    className="rounded-lg border border-border bg-surface-raised px-3 py-2.5"
                  >
                    <div className="flex items-center gap-2">
                      <Plug size={13} className="text-primary-light" />
                      <span className="text-xs font-semibold text-text">{suggestion.server_name}</span>
                      {effectiveStatus === "ready" && (
                        <span className="flex items-center gap-1 text-[10px] font-medium text-success">
                          <CheckCircle2 size={11} /> Connected
                        </span>
                      )}
                    </div>
                    <p className="mt-1 text-[11px] leading-snug text-text-secondary">{suggestion.reason}</p>

                    {effectiveStatus === "needs_grant" && grantId && (
                      <label className="mt-2 flex cursor-pointer items-center gap-2 text-[11px] text-text">
                        <input
                          type="checkbox"
                          checked={grantIds.has(grantId)}
                          onChange={(e) =>
                            setGrantIds((prev) => {
                              const next = new Set(prev);
                              if (e.target.checked) next.add(grantId);
                              else next.delete(grantId);
                              return next;
                            })
                          }
                          className="h-3.5 w-3.5 accent-[var(--mk-primary-500)]"
                        />
                        Allow the assigned agent to use this tool
                      </label>
                    )}

                    {effectiveStatus === "not_installed" &&
                      (suggestion.auth_kind === "api_key" || suggestion.auth_kind === "none" ? (
                        <div className="mt-2 flex items-center gap-2">
                          {suggestion.auth_kind === "api_key" && (
                            <input
                              className="mk-input h-8 flex-1 text-[11px]"
                              type="password"
                              placeholder="API key"
                              value={mcpKeys[suggestion.server_key] ?? ""}
                              onChange={(e) =>
                                setMcpKeys((prev) => ({ ...prev, [suggestion.server_key]: e.target.value }))
                              }
                            />
                          )}
                          <Button
                            variant="secondary"
                            size="sm"
                            loading={installMcp.isPending}
                            onClick={() => handleConnectMcp(suggestion.server_key)}
                          >
                            Connect
                          </Button>
                        </div>
                      ) : (
                        <Button
                          variant="secondary"
                          size="sm"
                          className="mt-2"
                          onClick={() => {
                            onOpenChange(false);
                            navigate({ to: "/integrations" });
                          }}
                        >
                          Connect in MCP Hub
                        </Button>
                      ))}
                  </div>
                );
              })}
            </div>
          )}

          {error && <p className="text-[11px] text-danger">{error}</p>}
        </div>
      )}

      {step === "done" && result && (
        <div className="flex flex-col items-center gap-3 py-6 text-center">
          <span className="flex h-12 w-12 items-center justify-center rounded-full bg-success/15 text-success">
            <CheckCircle2 size={24} />
          </span>
          <div>
            <p className="text-sm font-semibold text-text">“{result.taskTitle}”</p>
            {result.agentCreated && result.agentName && (
              <p className="mt-1 flex items-center justify-center gap-1.5 text-[11px] font-medium text-info">
                <Wand2 size={11} /> New agent “{result.agentName}” created and assigned
              </p>
            )}
            <p className="mt-1 text-xs text-text-muted">
              {result.agentName
                ? `${result.agentName} is on it. You'll be notified when it's ready for review.`
                : "Task created. Assign an agent to start the work."}
            </p>
          </div>
          <Button
            variant="secondary"
            size="sm"
            onClick={() => {
              // Make sure the pipeline the user lands on actually contains the task.
              if (workspaceId && result.projectId !== activeProjectId) {
                setActiveProject(workspaceId, result.projectId);
              }
              selectTask(result.taskId);
              onOpenChange(false);
              navigate({ to: "/tasks" });
            }}
          >
            View task
          </Button>
        </div>
      )}
    </Dialog>
  );
}
