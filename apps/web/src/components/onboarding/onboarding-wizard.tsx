import { useEffect, useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import {
  ArrowRight,
  Bot,
  Building2,
  CheckCircle2,
  FolderKanban,
  MessageSquareText,
  Plug,
  Sparkles,
  X,
} from "lucide-react";
import { apiFetch } from "@/api/client";
import {
  useCreateAgent,
  useCreateProject,
  useCreateTask,
  useExecuteAi,
  useUpdateWorkspace,
  useWorkspace,
} from "@/api/hooks";
import type { Envelope, Task } from "@/api/types";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Textarea } from "@/components/ui/textarea";
import { useAuthStore } from "@/stores/auth-store";
import { useOnboardingStore } from "@/stores/onboarding-store";
import { cn } from "@/lib/cn";

const steps = [
  { key: "welcome", label: "Welcome", icon: Building2 },
  { key: "project", label: "First project", icon: FolderKanban },
  { key: "agent", label: "First agent", icon: Bot },
  { key: "task", label: "First task", icon: MessageSquareText },
  { key: "mcp", label: "Connect tools", icon: Plug },
] as const;

const industries = [
  "Software",
  "E-commerce",
  "Marketing",
  "Finance",
  "Design",
  "Consulting",
  "Healthcare",
  "Other",
];

const skillPresets = ["Research", "Copywriting", "Reporting", "Planning", "Data analysis", "Support"];

export function OnboardingWizard({ onFinish }: { onFinish: () => void }) {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const user = useAuthStore((s) => s.user);
  const markWizardDone = useOnboardingStore((s) => s.markWizardDone);
  const startTour = useOnboardingStore((s) => s.startTour);
  const navigate = useNavigate();

  const { data: workspaceData } = useWorkspace();
  const updateWorkspace = useUpdateWorkspace();
  const createProject = useCreateProject();
  const createAgent = useCreateAgent();
  const createTask = useCreateTask();
  const executeAi = useExecuteAi();

  const [step, setStep] = useState(0);
  const [industry, setIndustry] = useState("");
  const [projectName, setProjectName] = useState("");
  const [projectDescription, setProjectDescription] = useState("");
  const [projectId, setProjectId] = useState<string | null>(null);
  const [agentName, setAgentName] = useState("Nova");
  const [agentRole, setAgentRole] = useState("");
  const [agentSkills, setAgentSkills] = useState<string[]>(["Research", "Planning"]);
  const [agentId, setAgentId] = useState<string | null>(null);
  const [taskText, setTaskText] = useState("");
  const [taskId, setTaskId] = useState<string | null>(null);

  const workspaceName = workspaceData?.data.name ?? "your workspace";
  const firstName = user?.full_name?.split(" ")[0] ?? "there";

  // Live agent reply: poll the created task until the agent posts its
  // acknowledgement comment (delivered by the AI worker).
  const { data: taskDetail } = useQuery({
    queryKey: ["onboarding-task", taskId],
    enabled: taskId != null && step === 3,
    refetchInterval: 2000,
    queryFn: () => apiFetch<Envelope<Task>>(`/api/tasks/${taskId}`),
  });

  const agentReply = useMemo(() => {
    const comments = taskDetail?.data.comments ?? [];
    return comments.find((c) => c.author_kind === "agent") ?? null;
  }, [taskDetail]);

  const [waitingSeconds, setWaitingSeconds] = useState(0);
  useEffect(() => {
    if (!taskId || agentReply || step !== 3) return;
    const timer = setInterval(() => setWaitingSeconds((s) => s + 1), 1000);
    return () => clearInterval(timer);
  }, [taskId, agentReply, step]);

  const finish = (goToMcpHub = false) => {
    if (workspaceId) markWizardDone(workspaceId);
    onFinish();
    if (goToMcpHub) {
      navigate({ to: "/integrations" });
    } else {
      startTour();
    }
  };

  const submitWelcome = async () => {
    if (industry) {
      await updateWorkspace.mutateAsync({ industry });
    }
    setStep(1);
  };

  const submitProject = async () => {
    if (!projectName.trim()) return;
    const created = await createProject.mutateAsync({
      name: projectName.trim(),
      description: projectDescription.trim() || undefined,
      status: "active",
      cover_kind: "meeting",
    });
    setProjectId(created.data.id);
    setStep(2);
  };

  const submitAgent = async () => {
    if (!agentName.trim()) return;
    const created = await createAgent.mutateAsync({
      display_name: agentName.trim(),
      role_title: agentRole.trim() || "Generalist",
      kind: "ai",
      ai_enabled: true,
      status: "active",
      presence_status: "online",
      skills: agentSkills.map((s) => ({ name: s, level: 80 })),
      avatar_config: { primary_color: "#7c5cff" },
    });
    setAgentId(created.data.id);
    setStep(3);
  };

  const submitTask = async () => {
    if (!taskText.trim() || !agentId) return;
    const [title, ...rest] = taskText.trim().split("\n");
    const created = await createTask.mutateAsync({
      title: title.slice(0, 120),
      description: taskText.trim(),
      project_id: projectId ?? undefined,
      assigned_agent_id: agentId,
    });
    setTaskId(created.data.id);
    setWaitingSeconds(0);
    executeAi.mutate({ taskId: created.data.id });
    void rest;
  };

  const busy =
    updateWorkspace.isPending ||
    createProject.isPending ||
    createAgent.isPending ||
    createTask.isPending;

  return (
    <div className="fixed inset-0 z-[80] flex items-center justify-center bg-bg-deep/95 backdrop-blur-sm">
      <div className="relative w-full max-w-xl px-6">
        <button
          onClick={() => finish()}
          className="absolute -top-10 right-6 flex items-center gap-1.5 rounded-md px-2 py-1 text-xs text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
        >
          Skip for now <X size={13} />
        </button>

        {/* Progress */}
        <div className="mb-8 flex items-center gap-2">
          {steps.map((s, i) => {
            const Icon = s.icon;
            return (
              <div key={s.key} className="flex flex-1 items-center gap-2">
                <span
                  className={cn(
                    "flex h-8 w-8 shrink-0 items-center justify-center rounded-full border transition-colors",
                    i < step
                      ? "border-success/50 bg-success-muted text-success"
                      : i === step
                        ? "border-primary/60 bg-primary-muted text-primary-light"
                        : "border-border bg-surface text-text-muted",
                  )}
                >
                  {i < step ? <CheckCircle2 size={15} /> : <Icon size={14} />}
                </span>
                {i < steps.length - 1 && (
                  <span
                    className={cn(
                      "h-px flex-1 transition-colors",
                      i < step ? "bg-success/40" : "bg-border",
                    )}
                  />
                )}
              </div>
            );
          })}
        </div>

        <div className="mk-card-raised p-8 mk-fade-up" key={step}>
          {step === 0 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">
                  Welcome, {firstName} 👋
                </h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  <span className="font-semibold text-text">{workspaceName}</span> is ready. In the
                  next 2 minutes you'll create a project, meet your first AI agent and give it a
                  task — in plain language. You can skip any step.
                </p>
              </div>
              <Field label="What does your company do?" hint="Helps your agents understand context.">
                <div className="flex flex-wrap gap-2">
                  {industries.map((ind) => (
                    <button
                      key={ind}
                      type="button"
                      onClick={() => setIndustry(ind)}
                      className={cn(
                        "rounded-full border px-3 py-1.5 text-xs font-medium transition-colors",
                        industry === ind
                          ? "border-primary/50 bg-primary-muted text-primary-light"
                          : "border-border text-text-muted hover:text-text",
                      )}
                    >
                      {ind}
                    </button>
                  ))}
                </div>
              </Field>
              <Button className="w-full" loading={busy} onClick={submitWelcome}>
                Let's go <ArrowRight size={14} />
              </Button>
            </div>
          )}

          {step === 1 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">Create your first project</h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  Projects keep tasks, agents and files organized around one goal. Don't overthink
                  it — you can rename it later.
                </p>
              </div>
              <Field label="Project name" required>
                <input
                  className="mk-input h-11"
                  placeholder="e.g. Website launch, Q3 campaign…"
                  value={projectName}
                  onChange={(e) => setProjectName(e.target.value)}
                  autoFocus
                />
              </Field>
              <Field label="What is it about?">
                <Textarea
                  className="min-h-[72px]"
                  placeholder="One or two sentences (optional)"
                  value={projectDescription}
                  onChange={(e) => setProjectDescription(e.target.value)}
                />
              </Field>
              <div className="flex gap-2">
                <Button variant="ghost" onClick={() => setStep(2)}>
                  Skip
                </Button>
                <Button
                  className="flex-1"
                  loading={busy}
                  disabled={!projectName.trim()}
                  onClick={submitProject}
                >
                  Create project <ArrowRight size={14} />
                </Button>
              </div>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">Meet your first AI agent</h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  Agents are AI teammates. Give yours a name and a role — it will introduce itself
                  in a moment.
                </p>
              </div>
              <div className="flex items-center gap-4">
                <Avatar name={agentName || "?"} size="lg" isAi color="#7c5cff" />
                <div className="flex-1 space-y-3">
                  <Field label="Name" required>
                    <input
                      className="mk-input"
                      value={agentName}
                      onChange={(e) => setAgentName(e.target.value)}
                    />
                  </Field>
                  <Field label="Role">
                    <input
                      className="mk-input"
                      placeholder="e.g. Marketing assistant"
                      value={agentRole}
                      onChange={(e) => setAgentRole(e.target.value)}
                    />
                  </Field>
                </div>
              </div>
              <Field label="Skills">
                <div className="flex flex-wrap gap-2">
                  {skillPresets.map((skill) => (
                    <button
                      key={skill}
                      type="button"
                      onClick={() =>
                        setAgentSkills((prev) =>
                          prev.includes(skill)
                            ? prev.filter((s) => s !== skill)
                            : [...prev, skill],
                        )
                      }
                      className={cn(
                        "rounded-full border px-3 py-1.5 text-xs font-medium transition-colors",
                        agentSkills.includes(skill)
                          ? "border-primary/50 bg-primary-muted text-primary-light"
                          : "border-border text-text-muted hover:text-text",
                      )}
                    >
                      {skill}
                    </button>
                  ))}
                </div>
              </Field>
              <div className="flex gap-2">
                <Button variant="ghost" onClick={() => setStep(3)}>
                  Skip
                </Button>
                <Button
                  className="flex-1"
                  loading={busy}
                  disabled={!agentName.trim()}
                  onClick={submitAgent}
                >
                  Create agent <ArrowRight size={14} />
                </Button>
              </div>
            </div>
          )}

          {step === 3 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">Give {agentName || "your agent"} a task</h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  Write it like you'd brief a colleague — plain language works best.
                </p>
              </div>

              {!taskId ? (
                <>
                  <Textarea
                    className="min-h-[96px]"
                    placeholder={"e.g. Research our 3 main competitors and summarize their pricing in a short report"}
                    value={taskText}
                    onChange={(e) => setTaskText(e.target.value)}
                    autoFocus
                  />
                  <div className="flex gap-2">
                    <Button variant="ghost" onClick={() => setStep(4)}>
                      Skip
                    </Button>
                    <Button
                      className="flex-1"
                      loading={busy || executeAi.isPending}
                      disabled={!taskText.trim() || !agentId}
                      onClick={submitTask}
                    >
                      <Sparkles size={14} /> Send to {agentName || "agent"}
                    </Button>
                  </div>
                  {!agentId && (
                    <p className="text-center text-[11px] text-text-muted">
                      You skipped agent creation — go back one step to create an agent first, or
                      skip this step.
                    </p>
                  )}
                </>
              ) : (
                <div className="space-y-4">
                  <div className="flex justify-end">
                    <div className="max-w-[85%] rounded-lg rounded-br-sm bg-primary-muted px-3.5 py-2.5 text-xs leading-relaxed text-text">
                      {taskText}
                    </div>
                  </div>
                  <div className="flex items-start gap-2.5">
                    <Avatar name={agentName} size="sm" isAi color="#7c5cff" />
                    {agentReply ? (
                      <div className="max-w-[85%] rounded-lg rounded-tl-sm bg-surface-overlay px-3.5 py-2.5 text-xs leading-relaxed text-text mk-fade-up">
                        {agentReply.body}
                      </div>
                    ) : (
                      <div className="flex items-center gap-1.5 rounded-lg rounded-tl-sm bg-surface-overlay px-3.5 py-3">
                        <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-text-muted" />
                        <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-text-muted animation-delay-150" />
                        <span className="h-1.5 w-1.5 animate-bounce rounded-full bg-text-muted animation-delay-300" />
                      </div>
                    )}
                  </div>
                  {agentReply || waitingSeconds > 12 ? (
                    <Button className="w-full" onClick={() => setStep(4)}>
                      {agentReply ? "Amazing — continue" : "Continue"} <ArrowRight size={14} />
                    </Button>
                  ) : (
                    <p className="text-center text-[11px] text-text-muted">
                      {agentName} is reading your task…
                    </p>
                  )}
                </div>
              )}
            </div>
          )}

          {step === 4 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">Connect your tools (optional)</h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  The MCP Hub lets you plug tools like Figma, GitHub, Slack or Notion into your
                  workspace — and decide exactly which agent can use which tool.
                </p>
              </div>
              <div className="grid grid-cols-4 gap-2">
                {["Figma", "GitHub", "Slack", "Notion", "Gmail", "Stripe", "Linear", "AWS"].map(
                  (tool) => (
                    <div
                      key={tool}
                      className="rounded-md border border-border bg-surface px-2 py-2.5 text-center text-[11px] font-medium text-text-secondary"
                    >
                      {tool}
                    </div>
                  ),
                )}
              </div>
              <div className="flex gap-2">
                <Button variant="ghost" className="flex-1" onClick={() => finish()}>
                  Finish — take the tour
                </Button>
                <Button className="flex-1" onClick={() => finish(true)}>
                  <Plug size={14} /> Open MCP Hub
                </Button>
              </div>
            </div>
          )}
        </div>

        <p className="mt-4 text-center text-[11px] text-text-muted">
          Step {step + 1} of {steps.length} · You can re-run the tour anytime from Settings
        </p>
      </div>
    </div>
  );
}
