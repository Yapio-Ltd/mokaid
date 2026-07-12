import { lazy, Suspense, useCallback, useEffect, useRef, useState } from "react";
import { useNavigate } from "@tanstack/react-router";

const AgentPreview3D = lazy(() =>
  import("@/three/agent-preview").then((m) => ({ default: m.AgentPreview3D })),
);
import {
  ArrowLeft,
  ArrowRight,
  Bot,
  Building2,
  Check,
  CheckCircle2,
  Coins,
  FolderKanban,
  Loader2,
  Mail,
  PartyPopper,
  Plug,
  Plus,
  Sparkles,
  Upload,
  Users,
  X,
} from "lucide-react";
import {
  useBillingOverview,
  useBillingPlans,
  useConnectIntegration,
  useCreateAgent,
  useCreateProject,
  useGithubOauthStart,
  useGoogleOauthStart,
  useLinearOauthStart,
  useNotionOauthStart,
  usePlanCheckout,
  useSlackOauthStart,
  useIntegrations,
  useInviteMember,
  useUpdateOnboarding,
  useUpdateWorkspace,
  useUploadWorkspaceLogo,
  useWorkspace,
} from "@/api/hooks";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Textarea } from "@/components/ui/textarea";
import { useAuthStore } from "@/stores/auth-store";
import { useOnboardingStore } from "@/stores/onboarding-store";
import { ApiError, fetchWorkspaceLogoBlob } from "@/api/client";
import { IntegrationLogo } from "@/components/integrations/integration-logo";
import { PlanPicker, BillingCycleToggle, type BillingCycle } from "@/components/billing/plan-picker";
import { cn } from "@/lib/cn";
import {
  consumeOnboardingRestoreStep,
  navigateOauthPopup,
  openOauthPopup,
  setOauthReturn,
} from "@/lib/oauth-callback";
import { useOauthPopupListener } from "@/lib/use-oauth-popup-listener";
import { toast } from "@/stores/toast-store";

/* ─── Steps config ─── */

const steps = [
  { key: "welcome", label: "Welcome", icon: Sparkles },
  { key: "workspace", label: "Workspace", icon: Building2 },
  { key: "integrations", label: "Tools", icon: Plug },
  { key: "agent", label: "First agent", icon: Bot },
  { key: "project", label: "First project", icon: FolderKanban },
  { key: "plan", label: "Plan", icon: Coins },
  { key: "done", label: "Ready", icon: PartyPopper },
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

const agentColors = ["#7c5cff", "#60a5fa", "#f472b6", "#34d399", "#fbbf24", "#22d3ee"];

const featuredIntegrations = ["github", "slack", "google_drive", "gmail", "notion", "linear"];

const googleProviderKeys = new Set([
  "google_drive",
  "gmail",
  "google_calendar",
  "google_docs",
  "google_sheets",
  "google_meet",
]);

const githubProviderKey = "github";
const linearProviderKey = "linear";
const notionProviderKey = "notion";
const slackProviderKey = "slack";

/* ─── Small pieces ─── */

function StepDots({ current }: { current: number }) {
  return (
    <div className="mb-6 flex items-center gap-1 sm:gap-2">
      {steps.map((s, i) => {
        const Icon = s.icon;
        return (
          <div key={s.key} className="flex min-w-0 flex-1 items-center gap-1 sm:gap-2">
            <div className="flex min-w-0 flex-col items-center gap-1.5">
              <span
                className={cn(
                  "flex h-9 w-9 shrink-0 items-center justify-center rounded-full transition-all duration-300",
                  i < current
                    ? "bg-success-muted text-success"
                    : i === current
                      ? "bg-primary text-white shadow-[0_0_20px_rgba(124,92,255,0.4)]"
                      : "bg-surface-raised text-text-muted",
                )}
              >
                {i < current ? <CheckCircle2 size={16} /> : <Icon size={15} />}
              </span>
              <span
                className={cn(
                  "max-w-[4.5rem] truncate text-center text-[9px] font-medium sm:max-w-none",
                  i === current ? "text-primary-light" : "text-text-muted",
                )}
              >
                {s.label}
              </span>
            </div>
            {i < steps.length - 1 && (
              <span
                className={cn(
                  "mb-4 h-0.5 min-w-2 flex-1 rounded-full transition-colors duration-500",
                  i < current ? "bg-success/40" : "bg-surface-raised",
                )}
              />
            )}
          </div>
        );
      })}
    </div>
  );
}

function FeatureCard({
  icon,
  title,
  body,
  delay,
}: {
  icon: React.ReactNode;
  title: string;
  body: string;
  delay: string;
}) {
  return (
    <div
      className="mk-fade-up rounded-xl bg-surface-raised/60 p-4 text-left"
      style={{ animationDelay: delay }}
    >
      <span className="mb-2.5 flex h-9 w-9 items-center justify-center rounded-lg bg-primary-muted text-primary-light">
        {icon}
      </span>
      <p className="text-xs font-semibold text-text">{title}</p>
      <p className="mt-1 text-[11px] leading-relaxed text-text-muted">{body}</p>
    </div>
  );
}

function LogoDropZone({
  previewUrl,
  uploading,
  onFile,
}: {
  previewUrl: string | null;
  uploading: boolean;
  onFile: (file: File) => void;
}) {
  const [dragActive, setDragActive] = useState(false);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const pickFile = useCallback(
    (files: FileList | File[]) => {
      const file = Array.from(files).find((f) => f.type.startsWith("image/"));
      if (file) onFile(file);
    },
    [onFile],
  );

  return (
    <div className="shrink-0">
      <input
        ref={fileInputRef}
        type="file"
        accept="image/png,image/jpeg,image/webp,image/gif"
        className="hidden"
        onChange={(e) => {
          if (e.target.files) pickFile(e.target.files);
          e.target.value = "";
        }}
      />
      <button
        type="button"
        aria-label="Upload company logo"
        onClick={() => fileInputRef.current?.click()}
        onDragOver={(e) => {
          e.preventDefault();
          setDragActive(true);
        }}
        onDragLeave={() => setDragActive(false)}
        onDrop={(e) => {
          e.preventDefault();
          setDragActive(false);
          pickFile(e.dataTransfer.files);
        }}
        className={cn(
          "group relative flex h-[4.5rem] w-[4.5rem] cursor-pointer flex-col items-center justify-center overflow-hidden rounded-2xl border-2 border-dashed transition-all",
          dragActive
            ? "border-primary bg-primary-muted/30"
            : "border-border/50 bg-surface-raised hover:border-primary/40 hover:bg-surface-hover/50",
        )}
      >
        {previewUrl ? (
          <img src={previewUrl} alt="Company logo" className="h-full w-full object-cover" />
        ) : uploading ? (
          <Loader2 size={22} className="animate-spin text-primary-light" />
        ) : (
          <>
            <Upload size={18} className="text-text-muted group-hover:text-primary-light" />
            <span className="mt-1 text-[9px] font-medium text-text-muted group-hover:text-text-secondary">
              Logo
            </span>
          </>
        )}
        {previewUrl && !uploading && (
          <span className="absolute inset-0 flex items-center justify-center bg-bg-deep/60 text-[9px] font-medium text-text opacity-0 transition-opacity group-hover:opacity-100">
            Change
          </span>
        )}
      </button>
      <p className="mt-1.5 max-w-[4.5rem] text-center text-[10px] leading-tight text-text-muted">
        Drop or click
      </p>
    </div>
  );
}

/* ═══════════════ Wizard ═══════════════ */

export function OnboardingWizard({ onFinish }: { onFinish: () => void }) {
  const user = useAuthStore((s) => s.user);
  const navigate = useNavigate();
  const startTour = useOnboardingStore((s) => s.startTour);

  const { data: workspaceData } = useWorkspace();
  const updateWorkspace = useUpdateWorkspace();
  const uploadLogo = useUploadWorkspaceLogo();
  const updateOnboarding = useUpdateOnboarding();
  const createProject = useCreateProject();
  const createAgent = useCreateAgent();
  const inviteMember = useInviteMember();
  const { data: integrationsData } = useIntegrations();
  const { data: plansData } = useBillingPlans();
  const { data: billingData } = useBillingOverview();
  const planCheckout = usePlanCheckout();
  const connectIntegration = useConnectIntegration();
  const googleOauthStart = useGoogleOauthStart();
  const githubOauthStart = useGithubOauthStart();
  const linearOauthStart = useLinearOauthStart();
  const notionOauthStart = useNotionOauthStart();
  const slackOauthStart = useSlackOauthStart();

  const [step, setStep] = useState(() => consumeOnboardingRestoreStep() ?? 0);
  const [billingCycle, setBillingCycle] = useState<BillingCycle>("monthly");

  // Back from a PayMe checkout started inside the wizard: the restore-step
  // mechanism already re-opened us at the right step — confirm the payment.
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get("payment") === "done") {
      setStep(6);
      toast({
        tone: "success",
        title: "Payment received",
        description: "Your plan is being activated — welcome aboard!",
        duration: 8000,
      });
      window.history.replaceState({}, "", window.location.pathname);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Workspace step
  const [companyName, setCompanyName] = useState("");
  const [logoPreview, setLogoPreview] = useState<string | null>(null);
  const [logoError, setLogoError] = useState<string | null>(null);
  const logoObjectUrlRef = useRef<string | null>(null);
  const [industry, setIndustry] = useState("");
  const [inviteEmails, setInviteEmails] = useState<string[]>([]);
  const [emailDraft, setEmailDraft] = useState("");

  // Integrations step
  const [connecting, setConnecting] = useState<string | null>(null);
  const [connectError, setConnectError] = useState<string | null>(null);

  useOauthPopupListener(() => setConnecting(null));

  // Agent step
  const [agentName, setAgentName] = useState("Nova");
  const [agentColor, setAgentColor] = useState(agentColors[0]);
  const [agentCreated, setAgentCreated] = useState(false);

  // Project step
  const [projectName, setProjectName] = useState("");
  const [projectDescription, setProjectDescription] = useState("");
  const [projectCreated, setProjectCreated] = useState(false);

  const firstName = user?.full_name?.split(" ")[0] ?? "there";
  const providers = integrationsData?.data.providers ?? [];
  const connections = integrationsData?.data.connections ?? [];
  const connectedKeys = new Set(
    connections.filter((c) => c.status === "connected").map((c) => c.provider_key),
  );

  const finish = (withTour: boolean) => {
    updateOnboarding.mutate({ wizard_done: true });
    onFinish();
    if (withTour) startTour();
  };

  // Plan step — real catalog, Free by default.
  const onboardingPlans = plansData?.data ?? [];
  const currentPlanKey = billingData?.data.subscription?.plan?.key ?? "free";

  const choosePlan = (planKey: string) => {
    if (planKey === "enterprise") {
      window.location.href =
        "mailto:sales@mokaid.com?subject=Mokaid%20Enterprise&body=Tell%20us%20about%20your%20team.";
      return;
    }
    if (planKey === "free" || planKey === currentPlanKey) {
      setStep(6);
      return;
    }
    // Paid plan → PayMe checkout (redirects; in dev it activates directly).
    // Before redirecting, remember to reopen the wizard on the next step so
    // the user lands back exactly where they left off.
    setOauthReturn("/dashboard", 6);
    planCheckout.mutate(
      { plan_key: planKey, billing_cycle: billingCycle, return_path: "/dashboard?payment=done" },
      {
        onSuccess: (result) => {
          if (result.data.activated) {
            toast({ tone: "success", title: "Plan activated", description: "Welcome aboard!" });
            setStep(6);
          }
        },
      },
    );
  };

  const addEmail = () => {
    const email = emailDraft.trim().toLowerCase();
    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return;
    if (!inviteEmails.includes(email)) setInviteEmails((prev) => [...prev, email]);
    setEmailDraft("");
  };

  const submitWorkspace = async () => {
    const updates: Record<string, string> = {};
    if (companyName.trim()) updates.name = companyName.trim();
    if (industry) updates.industry = industry;
    if (Object.keys(updates).length > 0) await updateWorkspace.mutateAsync(updates);
    for (const email of inviteEmails) {
      try {
        await inviteMember.mutateAsync({ email });
      } catch {
        // Invite failures shouldn't block onboarding.
      }
    }
    setStep(2);
  };

  const toggleConnect = async (key: string) => {
    if (connectedKeys.has(key)) return;
    setConnecting(key);
    setConnectError(null);
    const popup = openOauthPopup();
    try {
      if (key === githubProviderKey) {
        const result = await githubOauthStart.mutateAsync(
          `${window.location.origin}/oauth/github/callback`,
        );
        navigateOauthPopup(popup, result.data.authorize_url, { step });
        return;
      }
      if (googleProviderKeys.has(key)) {
        const result = await googleOauthStart.mutateAsync({
          redirect_uri: `${window.location.origin}/oauth/google/callback`,
          provider_key: key,
        });
        navigateOauthPopup(popup, result.data.authorize_url, { step });
        return;
      }
      if (key === linearProviderKey) {
        const result = await linearOauthStart.mutateAsync(
          `${window.location.origin}/oauth/linear/callback`,
        );
        navigateOauthPopup(popup, result.data.authorize_url, { step });
        return;
      }
      if (key === slackProviderKey) {
        const result = await slackOauthStart.mutateAsync(
          `${window.location.origin}/oauth/slack/callback`,
        );
        navigateOauthPopup(popup, result.data.authorize_url, { step });
        return;
      }
      if (key === notionProviderKey) {
        const result = await notionOauthStart.mutateAsync(
          `${window.location.origin}/auth/notion/callback`,
        );
        navigateOauthPopup(popup, result.data.authorize_url, { step });
        return;
      }
      popup?.close();
      await connectIntegration.mutateAsync(key);
    } catch (err) {
      popup?.close();
      const message =
        err instanceof ApiError && err.code === "oauth_not_configured"
          ? key === slackProviderKey
            ? "Slack OAuth is not configured on the API. Add SLACK_CLIENT_ID and SLACK_CLIENT_SECRET to apps/api/.env, then restart the API."
            : key === notionProviderKey
              ? "Notion OAuth is not configured on the API. Add NOTION_CLIENT_ID and NOTION_CLIENT_SECRET to apps/api/.env, then restart the API."
            : key === linearProviderKey
              ? "Linear OAuth is not configured on the API. Add LINEAR_CLIENT_ID and LINEAR_CLIENT_SECRET to apps/api/.env, then restart the API."
              : "Google OAuth is not configured on the API. Add GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET to apps/api/.env, then restart the API."
          : err instanceof ApiError
            ? err.message
            : "Connection failed. Please try again.";
      setConnectError(message);
      toast({ tone: "error", title: "Connection failed", description: message });
    } finally {
      if (!popup || popup.closed) {
        setConnecting(null);
      }
    }
  };

  const submitAgent = async () => {
    if (!agentName.trim()) return;
    await createAgent.mutateAsync({
      display_name: agentName.trim(),
      role_title: "Generalist",
      kind: "ai",
      ai_enabled: true,
      status: "idle",
      presence_status: "online",
      skills: [],
      avatar_config: { primary_color: agentColor, seat_index: 0 },
    });
    setAgentCreated(true);
    setTimeout(() => setStep(4), 700);
  };

  const submitProject = async () => {
    if (!projectName.trim()) return;
    await createProject.mutateAsync({
      name: projectName.trim(),
      description: projectDescription.trim() || undefined,
      status: "active",
      cover_kind: "meeting",
    });
    setProjectCreated(true);
    setTimeout(() => setStep(5), 700);
  };

  const busy =
    updateWorkspace.isPending || createProject.isPending || createAgent.isPending;

  const setLogoObjectUrl = useCallback((url: string | null) => {
    if (logoObjectUrlRef.current) {
      URL.revokeObjectURL(logoObjectUrlRef.current);
      logoObjectUrlRef.current = null;
    }
    if (url?.startsWith("blob:")) {
      logoObjectUrlRef.current = url;
    }
    setLogoPreview(url);
  }, []);

  useEffect(() => {
    const workspaceId = workspaceData?.data.id;
    const hasLogo =
      workspaceData?.data.has_logo ||
      Boolean(
        (workspaceData?.data.settings as Record<string, unknown> | null)?.logo_storage_key,
      );

    if (!workspaceId || !hasLogo || logoPreview) return;

    let cancelled = false;
    fetchWorkspaceLogoBlob(workspaceId).then((blob) => {
      if (cancelled || !blob) return;
      setLogoObjectUrl(URL.createObjectURL(blob));
    });

    return () => {
      cancelled = true;
    };
  }, [workspaceData?.data, logoPreview, setLogoObjectUrl]);

  useEffect(
    () => () => {
      if (logoObjectUrlRef.current) URL.revokeObjectURL(logoObjectUrlRef.current);
    },
    [],
  );

  const handleLogoFile = useCallback(
    (file: File) => {
      setLogoError(null);
      const preview = URL.createObjectURL(file);
      setLogoObjectUrl(preview);
      uploadLogo.mutate(file, {
        onSuccess: async (res) => {
          const workspaceId = res.data.id;
          const blob = await fetchWorkspaceLogoBlob(workspaceId);
          if (blob) {
            setLogoObjectUrl(URL.createObjectURL(blob));
          }
        },
        onError: (error) => {
          setLogoObjectUrl(null);
          setLogoError(
            error instanceof Error ? error.message : "Logo upload failed. Try again.",
          );
        },
      });
    },
    [uploadLogo, setLogoObjectUrl],
  );

  const logoDisplay = logoPreview;

  return (
    <div className="fixed inset-0 z-[80] flex items-center justify-center overflow-y-auto bg-bg-deep/95 backdrop-blur-md">
      <div className="relative my-8 w-full max-w-2xl px-6">
        <div className="mb-2 flex justify-end">
          <button
            type="button"
            onClick={() => finish(false)}
            className="flex shrink-0 items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-xs text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
          >
            Skip for now <X size={13} />
          </button>
        </div>

        <StepDots current={step} />

        <div
          key={step}
          className="mk-fade-up rounded-2xl bg-surface p-8 shadow-[0_16px_60px_rgba(0,0,0,0.4)]"
        >
          {/* ── Step 0 : Welcome ── */}
          {step === 0 && (
            <div className="space-y-6 text-center">
              <Sparkles size={36} strokeWidth={1.75} className="mk-ai-icon-shimmer" />
              <div>
                <h2 className="text-2xl font-bold text-text">
                  Welcome to mokaid, {firstName}
                </h2>
                <p className="mx-auto mt-2 max-w-md text-sm leading-relaxed text-text-secondary">
                  Your AI Workforce OS. Build a team of AI agents that work alongside you.
                  They take tasks, produce real deliverables and ask for approval when it
                  matters.
                </p>
              </div>
              <div className="grid grid-cols-3 gap-3">
                <FeatureCard
                  icon={<Bot size={17} />}
                  title="AI Agents"
                  body="Hire agents with skills. They work autonomously on your tasks."
                  delay="0.05s"
                />
                <FeatureCard
                  icon={<FolderKanban size={17} />}
                  title="Projects & Tasks"
                  body="Brief in plain language. Track progress on a live kanban."
                  delay="0.15s"
                />
                <FeatureCard
                  icon={<Plug size={17} />}
                  title="Your Tools"
                  body="Slack, GitHub, Google… decide which agent uses which tool."
                  delay="0.25s"
                />
              </div>
              <Button size="lg" className="w-full" onClick={() => setStep(1)}>
                Set up my workspace <ArrowRight size={15} />
              </Button>
              <p className="text-[11px] text-text-muted">Takes about 2 minutes · every step is skippable</p>
            </div>
          )}

          {/* ── Step 1 : Workspace setup ── */}
          {step === 1 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">Set up your workspace</h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  Tell us about your company. This gives your agents context to work with.
                </p>
              </div>

              <div className="flex items-start gap-4">
                <LogoDropZone
                  previewUrl={logoDisplay}
                  uploading={uploadLogo.isPending}
                  onFile={handleLogoFile}
                />
                <div className="min-w-0 flex-1">
                  <Field label="Company name" required>
                    <input
                      className="mk-input h-11"
                      placeholder="Acme Inc."
                      value={companyName}
                      onChange={(e) => setCompanyName(e.target.value)}
                      autoFocus
                    />
                  </Field>
                  {logoError && (
                    <p className="mt-2 text-[11px] text-danger">{logoError}</p>
                  )}
                </div>
              </div>

              <Field label="What does your company do?">
                <div className="flex flex-wrap gap-2">
                  {industries.map((ind) => (
                    <button
                      key={ind}
                      type="button"
                      onClick={() => setIndustry(industry === ind ? "" : ind)}
                      className={cn(
                        "rounded-full px-3.5 py-1.5 text-xs font-medium transition-all",
                        industry === ind
                          ? "bg-primary text-white shadow-[0_2px_12px_rgba(124,92,255,0.35)]"
                          : "bg-surface-raised text-text-muted hover:text-text",
                      )}
                    >
                      {ind}
                    </button>
                  ))}
                </div>
              </Field>

              <Field label="Invite your team" hint="They'll get an email invite. You can also do this later.">
                <div className="flex gap-2">
                  <input
                    className="mk-input flex-1"
                    placeholder="colleague@company.com"
                    value={emailDraft}
                    onChange={(e) => setEmailDraft(e.target.value)}
                    onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addEmail())}
                  />
                  <Button variant="secondary" size="icon" onClick={addEmail} aria-label="Add email">
                    <Plus size={14} />
                  </Button>
                </div>
                {inviteEmails.length > 0 && (
                  <div className="mt-2 flex flex-wrap gap-1.5">
                    {inviteEmails.map((email) => (
                      <span
                        key={email}
                        className="flex items-center gap-1.5 rounded-full bg-primary-muted px-2.5 py-1 text-[11px] text-primary-light"
                      >
                        <Mail size={10} /> {email}
                        <button
                          onClick={() =>
                            setInviteEmails((prev) => prev.filter((e) => e !== email))
                          }
                          className="hover:text-text"
                        >
                          <X size={10} />
                        </button>
                      </span>
                    ))}
                  </div>
                )}
              </Field>

              <div className="flex gap-2">
                <Button variant="ghost" onClick={() => setStep(0)}>
                  <ArrowLeft size={14} />
                </Button>
                <Button variant="ghost" onClick={() => setStep(2)}>
                  Skip
                </Button>
                <Button
                  className="flex-1"
                  loading={busy || inviteMember.isPending}
                  disabled={!companyName.trim()}
                  onClick={submitWorkspace}
                >
                  Continue <ArrowRight size={14} />
                </Button>
              </div>
            </div>
          )}

          {/* ── Step 2 : Integrations ── */}
          {step === 2 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">Connect your tools</h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  Plug in the tools your team already uses. Agents will be able to work with
                  them, with your permission.
                </p>
              </div>

              <div className="grid grid-cols-2 gap-2.5">
                {featuredIntegrations.map((key) => {
                  const provider = providers.find((p) => p.key === key);
                  if (!provider) return null;
                  const connected = connectedKeys.has(key);
                  const isConnecting = connecting === key;
                  return (
                    <button
                      key={key}
                      type="button"
                      disabled={connected || isConnecting}
                      onClick={() => toggleConnect(key)}
                      className={cn(
                        "flex items-center gap-3 rounded-xl p-3.5 text-left transition-all",
                        connected
                          ? "bg-success-muted/40"
                          : "bg-surface-raised/60 hover:bg-surface-hover hover:shadow-[0_2px_12px_rgba(0,0,0,0.15)]",
                      )}
                    >
                      <IntegrationLogo
                        providerKey={provider.key}
                        logoUrl={provider.logo_url}
                        name={provider.name}
                        size="sm"
                        onDark
                      />
                      <span className="min-w-0 flex-1">
                        <span className="block text-xs font-semibold text-text">
                          {provider.name}
                        </span>
                        <span className="block truncate text-[10px] text-text-muted">
                          {provider.category}
                        </span>
                      </span>
                      {isConnecting ? (
                        <Loader2 size={14} className="animate-spin text-text-muted" />
                      ) : connected ? (
                        <span
                          className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-success text-white shadow-[0_0_14px_rgba(34,197,94,0.45)]"
                          aria-label="Connected"
                        >
                          <CheckCircle2 size={18} strokeWidth={2.25} />
                        </span>
                      ) : (
                        <Plus size={14} className="text-text-muted" />
                      )}
                    </button>
                  );
                })}
              </div>

              {connectError && (
                <p className="rounded-xl border border-danger/30 bg-danger/10 px-4 py-3 text-xs leading-relaxed text-danger">
                  {connectError}
                </p>
              )}

              {providers.length === 0 && (
                <p className="rounded-xl bg-surface-raised/60 px-4 py-3 text-center text-xs text-text-muted">
                  Integrations catalog is loading… you can also connect tools later from the
                  MCP Hub.
                </p>
              )}

              <div className="flex gap-2">
                <Button variant="ghost" onClick={() => setStep(1)}>
                  <ArrowLeft size={14} />
                </Button>
                <Button className="flex-1" onClick={() => setStep(3)}>
                  {connectedKeys.size > 0 ? "Continue" : "Skip for now"} <ArrowRight size={14} />
                </Button>
              </div>
            </div>
          )}

          {/* ── Step 3 : First agent ── */}
          {step === 3 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">Meet your first AI agent</h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  Your agent starts with a clean slate. As you send it missions it will
                  learn, grow stronger, and gradually specialise — no setup required.
                </p>
              </div>

              {/* 2-column layout: 3D preview left, controls right */}
              <div className="flex items-start gap-5">
                {/* 3D character preview */}
                <div className="relative shrink-0 overflow-hidden rounded-xl border border-border bg-surface-raised/30">
                  <Suspense
                    fallback={
                      <div
                        className="flex items-center justify-center"
                        style={{ width: 220, height: 300 }}
                      >
                        <Avatar name={agentName || "?"} size="xl" isAi color={agentColor} />
                      </div>
                    }
                  >
                    <AgentPreview3D color={agentColor} name={agentName || "?"} width={220} height={300} />
                  </Suspense>
                  {agentCreated && (
                    <span className="absolute bottom-3 right-3 flex h-7 w-7 items-center justify-center rounded-full bg-success text-white shadow-lg mk-fade-up">
                      <Check size={14} />
                    </span>
                  )}
                </div>

                {/* Name + color */}
                <div className="flex flex-1 flex-col gap-4 pt-1">
                  <Field label="Name" required>
                    <input
                      className="mk-input"
                      value={agentName}
                      onChange={(e) => setAgentName(e.target.value)}
                    />
                  </Field>

                  <Field label="Color">
                    <div className="flex flex-wrap gap-2">
                      {agentColors.map((color) => (
                        <button
                          key={color}
                          type="button"
                          onClick={() => setAgentColor(color)}
                          aria-label={`Color ${color}`}
                          className={cn(
                            "h-8 w-8 rounded-full transition-transform",
                            agentColor === color &&
                              "scale-110 ring-2 ring-white/60 ring-offset-2 ring-offset-surface",
                          )}
                          style={{ backgroundColor: color }}
                        />
                      ))}
                    </div>
                  </Field>

                  <div className="rounded-lg border border-border bg-surface-raised/40 px-3 py-2.5 text-xs leading-relaxed text-text-muted">
                    <Sparkles size={11} className="mb-0.5 mr-1 inline text-primary-light" />
                    Skills and role are assigned automatically as your agent completes missions.
                  </div>
                </div>
              </div>

              <div className="flex gap-2">
                <Button variant="ghost" onClick={() => setStep(2)}>
                  <ArrowLeft size={14} />
                </Button>
                <Button variant="ghost" onClick={() => setStep(4)}>
                  Skip
                </Button>
                <Button
                  className="flex-1"
                  loading={busy}
                  disabled={!agentName.trim() || agentCreated}
                  onClick={submitAgent}
                >
                  {agentCreated ? (
                    <>
                      <Check size={14} /> Created!
                    </>
                  ) : (
                    <>
                      <Bot size={14} /> Create {agentName || "agent"}
                    </>
                  )}
                </Button>
              </div>
            </div>
          )}

          {/* ── Step 4 : First project ── */}
          {step === 4 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">Create your first project</h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  Projects group tasks, agents and files around one goal. Don't overthink it.
                  You can rename it anytime.
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
                <Button variant="ghost" onClick={() => setStep(3)}>
                  <ArrowLeft size={14} />
                </Button>
                <Button variant="ghost" onClick={() => setStep(5)}>
                  Skip
                </Button>
                <Button
                  className="flex-1"
                  loading={busy}
                  disabled={!projectName.trim() || projectCreated}
                  onClick={submitProject}
                >
                  {projectCreated ? (
                    <>
                      <Check size={14} /> Created!
                    </>
                  ) : (
                    <>
                      <FolderKanban size={14} /> Create project
                    </>
                  )}
                </Button>
              </div>
            </div>
          )}

          {/* ── Step 5 : Choose a plan ── */}
          {step === 5 && (
            <div className="space-y-5">
              <div>
                <h2 className="text-xl font-bold text-text">Choose your plan</h2>
                <p className="mt-1.5 text-sm leading-relaxed text-text-secondary">
                  Every plan includes a monthly pool of AI credits — the fuel your employees
                  spend as they work. Start free, upgrade anytime.
                </p>
              </div>

              <div className="flex justify-center">
                <BillingCycleToggle cycle={billingCycle} onChange={setBillingCycle} />
              </div>

              <PlanPicker
                plans={onboardingPlans}
                currentKey={currentPlanKey}
                pendingKey={planCheckout.isPending ? planCheckout.variables?.plan_key : undefined}
                onChoose={choosePlan}
                cycle={billingCycle}
                compact
              />

              <div className="flex gap-2">
                <Button variant="ghost" onClick={() => setStep(4)}>
                  <ArrowLeft size={14} />
                </Button>
                <Button variant="ghost" className="flex-1" onClick={() => setStep(6)}>
                  Continue with Free
                </Button>
              </div>
            </div>
          )}

          {/* ── Step 6 : Done ── */}
          {step === 6 && (
            <div className="space-y-6 text-center">
              <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-full bg-success-muted mk-float">
                <PartyPopper size={28} className="text-success" />
              </div>
              <div>
                <h2 className="text-2xl font-bold text-text">You're all set!</h2>
                <p className="mx-auto mt-2 max-w-md text-sm leading-relaxed text-text-secondary">
                  Your workspace is ready. Take a quick interactive tour to discover the
                  interface, or dive right in.
                </p>
              </div>

              <div className="grid grid-cols-3 gap-3 text-left">
                <div className="rounded-xl bg-surface-raised/60 p-3.5">
                  <Bot size={15} className="mb-2 text-primary-light" />
                  <p className="text-[11px] font-semibold text-text">
                    {agentCreated ? `${agentName} is ready` : "No agent yet"}
                  </p>
                  <p className="text-[10px] text-text-muted">
                    {agentCreated ? "Waiting at their desk" : "Create one anytime"}
                  </p>
                </div>
                <div className="rounded-xl bg-surface-raised/60 p-3.5">
                  <FolderKanban size={15} className="mb-2 text-primary-light" />
                  <p className="text-[11px] font-semibold text-text">
                    {projectCreated ? projectName : "No project yet"}
                  </p>
                  <p className="text-[10px] text-text-muted">
                    {projectCreated ? "Ready for tasks" : "Create one anytime"}
                  </p>
                </div>
                <div className="rounded-xl bg-surface-raised/60 p-3.5">
                  <Users size={15} className="mb-2 text-primary-light" />
                  <p className="text-[11px] font-semibold text-text">
                    {inviteEmails.length > 0
                      ? `${inviteEmails.length} invite${inviteEmails.length > 1 ? "s" : ""} sent`
                      : "Solo for now"}
                  </p>
                  <p className="text-[10px] text-text-muted">Invite more from Members</p>
                </div>
              </div>

              <div className="flex gap-2">
                <Button
                  variant="secondary"
                  className="flex-1"
                  onClick={() => {
                    finish(false);
                    navigate({ to: "/dashboard" });
                  }}
                >
                  Go to dashboard
                </Button>
                <Button className="flex-1" onClick={() => finish(true)}>
                  <Sparkles size={14} /> Take the tour
                </Button>
              </div>
            </div>
          )}
        </div>

        <p className="mt-4 text-center text-[11px] text-text-muted">
          Step {step + 1} of {steps.length} · Replay anytime from Workspace Settings
        </p>
      </div>
    </div>
  );
}
