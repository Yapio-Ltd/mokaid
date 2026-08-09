import {
  lazy,
  Suspense,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";

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
  useAgentCatalog,
  useBillingOverview,
  useBillingPlans,
  useConnectIntegration,
  useCreateAgent,
  useCreateProject,
  useGithubOauthStart,
  useGoogleOauthStart,
  useLinearOauthStart,
  useMailAccounts,
  useMicrosoftOauthStart,
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
import { recommendAgentPacks } from "@/lib/recommend-agent-packs";
import { formatNumber } from "@/lib/format";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { Textarea } from "@/components/ui/textarea";
import { useAuthStore } from "@/stores/auth-store";
import { useOnboardingStore } from "@/stores/onboarding-store";
import { ApiError, fetchWorkspaceLogoBlob } from "@/api/client";
import { IntegrationLogo } from "@/components/integrations/integration-logo";
import { ImapConnectDialog } from "@/components/mail/imap-connect-dialog";
import { PlanPicker, BillingCycleToggle, type BillingCycle } from "@/components/billing/plan-picker";
import {
  TranzilaCheckoutDialog,
  type CheckoutOutcome,
} from "@/components/billing/checkout-dialog";
import { cn } from "@/lib/cn";
import {
  consumeOnboardingRestoreStep,
  navigateOauthPopup,
  openOauthPopup,
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
const microsoftProviderKey = "outlook";

/* ─── Small pieces ─── */

function StepDots({ current }: { current: number }) {
  return (
    <div className="flex items-center gap-1 sm:gap-1.5" role="list" aria-label="Onboarding progress">
      {steps.map((s, i) => {
        const Icon = s.icon;
        return (
          <div key={s.key} className="flex min-w-0 flex-1 items-center gap-1 sm:gap-1.5" role="listitem">
            <span
              title={s.label}
              className={cn(
                "flex h-7 w-7 shrink-0 items-center justify-center rounded-full transition-all duration-300",
                i < current
                  ? "bg-success-muted text-success"
                  : i === current
                    ? "bg-primary text-white shadow-[0_0_16px_rgba(124,92,255,0.35)]"
                    : "bg-surface-raised text-text-muted",
              )}
            >
              {i < current ? <CheckCircle2 size={13} /> : <Icon size={13} />}
            </span>
            {i < steps.length - 1 && (
              <span
                className={cn(
                  "h-0.5 min-w-1.5 flex-1 rounded-full transition-colors duration-500",
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

/** Primary/secondary actions for a step — no divider, sits flush with form. */
function StepActions({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("mt-4 flex items-center gap-2", className)}>{children}</div>;
}

function FeatureCard({
  icon,
  title,
  body,
  delay,
}: {
  icon: ReactNode;
  title: string;
  body: string;
  delay: string;
}) {
  return (
    <div
      className="mk-fade-up rounded-xl bg-surface-raised/60 p-3 text-left"
      style={{ animationDelay: delay }}
    >
      <span className="mb-1.5 flex h-8 w-8 items-center justify-center rounded-lg bg-primary-muted text-primary-light">
        {icon}
      </span>
      <p className="text-xs font-semibold text-text">{title}</p>
      <p className="mt-0.5 text-[11px] leading-snug text-text-muted">{body}</p>
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
          "group relative flex h-14 w-14 cursor-pointer flex-col items-center justify-center overflow-hidden rounded-xl border border-dashed transition-all sm:h-[3.75rem] sm:w-[3.75rem]",
          dragActive
            ? "border-primary bg-primary-muted/30"
            : "border-border/60 bg-surface-raised hover:border-primary/40 hover:bg-surface-hover/50",
        )}
      >
        {previewUrl ? (
          <img src={previewUrl} alt="Company logo" className="h-full w-full object-cover" />
        ) : uploading ? (
          <Loader2 size={18} className="animate-spin text-primary-light" />
        ) : (
          <>
            <Upload size={15} className="text-text-muted group-hover:text-primary-light" />
            <span className="mt-0.5 text-[9px] font-medium text-text-muted group-hover:text-text-secondary">
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
  const { data: catalogData } = useAgentCatalog();
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
  const microsoftOauthStart = useMicrosoftOauthStart();
  const { data: mailAccountsData } = useMailAccounts();

  const [step, setStep] = useState(() => consumeOnboardingRestoreStep() ?? 0);
  const [billingCycle, setBillingCycle] = useState<BillingCycle>("monthly");
  // Embedded Tranzila checkout for paid plans — the wizard stays open.
  const [checkoutUrl, setCheckoutUrl] = useState<string | null>(null);
  const queryClient = useQueryClient();

  // Workspace step
  const [companyName, setCompanyName] = useState("");
  const [logoPreview, setLogoPreview] = useState<string | null>(null);
  const [logoError, setLogoError] = useState<string | null>(null);
  const logoObjectUrlRef = useRef<string | null>(null);
  const [industry, setIndustry] = useState("");
  const [companySummary, setCompanySummary] = useState("");
  const [agentNeeds, setAgentNeeds] = useState("");
  const [inviteEmails, setInviteEmails] = useState<string[]>([]);
  const [emailDraft, setEmailDraft] = useState("");

  // Integrations step
  const [connecting, setConnecting] = useState<string | null>(null);
  const [connectError, setConnectError] = useState<string | null>(null);
  const [imapDialogOpen, setImapDialogOpen] = useState(false);

  useOauthPopupListener(() => setConnecting(null));

  // Agent step
  const [agentName, setAgentName] = useState("Nova");
  const [agentColor, setAgentColor] = useState(agentColors[0]);
  const [agentCreated, setAgentCreated] = useState(false);
  const [agentPath, setAgentPath] = useState<"blank" | "specialist">("blank");
  const [archetypeKey, setArchetypeKey] = useState("blank");
  const [agentError, setAgentError] = useState<string | null>(null);

  // Project step
  const [projectName, setProjectName] = useState("");
  const [projectDescription, setProjectDescription] = useState("");
  const [projectCreated, setProjectCreated] = useState(false);

  const firstName = user?.full_name?.split(" ")[0] ?? "there";
  const archetypes = catalogData?.data.archetypes ?? [];
  const specialistCredits = catalogData?.data.specialist_credits ?? 5000;
  const spendable = billingData?.data.credits.spendable ?? 0;
  const briefText = `${companySummary} ${agentNeeds} ${industry}`.trim();
  const specialists = useMemo(
    () => archetypes.filter((a) => a.tier === "specialist" || (a.key !== "blank" && a.tier !== "blank")),
    [archetypes],
  );
  const recommended = useMemo(
    () => recommendAgentPacks(archetypes, briefText, 3),
    [archetypes, briefText],
  );
  const recommendedKeys = useMemo(() => new Set(recommended.map((a) => a.key)), [recommended]);
  const selectedArchetype =
    archetypes.find((a) => a.key === archetypeKey) ??
    specialists.find((a) => a.key === archetypeKey) ??
    specialists[0];
  const canAffordSpecialist = spendable >= specialistCredits;
  const providers = integrationsData?.data.providers ?? [];
  const connections = integrationsData?.data.connections ?? [];
  const connectedKeys = new Set(
    connections.filter((c) => c.status === "connected").map((c) => c.provider_key),
  );
  const imapConnected = (mailAccountsData?.data ?? []).some((a) => a.provider === "imap");

  const finish = (withTour: boolean) => {
    updateOnboarding.mutate({ wizard_done: true });
    onFinish();
    if (withTour) startTour();
  };

  // Plan step — real catalog, Free by default.
  const onboardingPlans = plansData?.data ?? [];
  const currentPlanKey = billingData?.data.subscription?.plan?.key ?? "free";

  const choosePlan = (planKey: string) => {
    if (planKey === "free" || planKey === currentPlanKey) {
      setStep(6);
      return;
    }
    // Paid plan → embedded Tranzila checkout modal (in dev without Tranzila
    // credentials the plan activates directly).
    planCheckout.mutate(
      { plan_key: planKey, billing_cycle: billingCycle },
      {
        onSuccess: (result) => {
          if (result.data.sale_url) {
            setCheckoutUrl(result.data.sale_url);
          } else if (result.data.activated) {
            toast({ tone: "success", title: "Plan activated", description: "Welcome aboard!" });
            setStep(6);
          }
        },
      },
    );
  };

  const handleCheckoutComplete = (outcome: CheckoutOutcome) => {
    setCheckoutUrl(null);
    if (outcome === "done") {
      // Activation is confirmed asynchronously by the notify webhook.
      queryClient.invalidateQueries({ queryKey: ["billing"] });
      setTimeout(() => queryClient.invalidateQueries({ queryKey: ["billing"] }), 4_000);
      toast({
        tone: "success",
        title: "Payment received",
        description: "Your plan is being activated — welcome aboard!",
        duration: 8000,
      });
      setStep(6);
    } else {
      toast({
        tone: "error",
        title: "Payment failed",
        description: "Your card was not charged. Please try again.",
      });
    }
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
    if (companySummary.trim()) updates.description = companySummary.trim();
    if (Object.keys(updates).length > 0) await updateWorkspace.mutateAsync(updates);
    await updateOnboarding.mutateAsync({
      company_summary: companySummary.trim() || undefined,
      agent_needs: agentNeeds.trim() || undefined,
    });
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
      if (key === microsoftProviderKey) {
        const result = await microsoftOauthStart.mutateAsync(
          `${window.location.origin}/oauth/microsoft/callback`,
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
              : key === microsoftProviderKey
                ? "Microsoft OAuth is not configured on the API. Add MICROSOFT_CLIENT_ID and MICROSOFT_CLIENT_SECRET to apps/api/.env, then restart the API."
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
    setAgentError(null);
    const brief = [companySummary.trim(), agentNeeds.trim()].filter(Boolean).join("\n\n");

    try {
      if (agentPath === "specialist") {
        const key = archetypeKey === "blank" ? selectedArchetype?.key : archetypeKey;
        if (!key || key === "blank") {
          setAgentError("Choose a specialist domain.");
          return;
        }
        if (!canAffordSpecialist) {
          setAgentError(`Need ${specialistCredits} credits for a level-10 specialist.`);
          return;
        }
        const created = await createAgent.mutateAsync({
          display_name: agentName.trim(),
          kind: "ai",
          archetype_key: key,
          boost_key: "boost_l10",
          knowledge_brief: brief || undefined,
          role_title: selectedArchetype?.role_title,
          department: selectedArchetype?.department,
          avatar_config: { primary_color: agentColor },
        });
        setAgentCreated(true);
        // Head-start training cinematic — close wizard and show level climb.
        void updateOnboarding.mutateAsync({ wizard_done: true }).catch(() => undefined);
        onFinish();
        void navigate({
          to: "/agents/$agentId/training",
          params: { agentId: created.data.id },
        });
        return;
      }

      await createAgent.mutateAsync({
        display_name: agentName.trim(),
        kind: "ai",
        archetype_key: "blank",
        knowledge_brief: brief || undefined,
        avatar_config: { primary_color: agentColor },
      });
      setAgentCreated(true);
      setTimeout(() => setStep(4), 700);
    } catch (e) {
      setAgentError(e instanceof ApiError ? e.message : e instanceof Error ? e.message : "Could not create agent.");
    }
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
    <div className="fixed inset-0 z-[80] overflow-y-auto overscroll-contain bg-bg-deep/95 backdrop-blur-md">
      {/* Centered when short; top-aligned fallback if content exceeds viewport */}
      <div className="flex min-h-[100dvh] items-center justify-center p-3 sm:p-5">
        <div className="relative my-auto w-full max-w-5xl">
          {/*
            Wide card, height capped to viewport. Prefer fitting without scroll via
            dense multi-column layouts; overflow is a safety net only.
          */}
          <div
            key={step}
            className="mk-fade-up max-h-[calc(100dvh-1.5rem)] overflow-y-auto overscroll-contain rounded-2xl bg-surface shadow-[0_16px_60px_rgba(0,0,0,0.4)] sm:max-h-[calc(100dvh-2.5rem)]"
          >
            <div className="px-5 py-4 sm:px-7 sm:py-5">
              {/* Chrome: progress + skip */}
              <div className="mb-4 flex items-center gap-3 sm:mb-5">
                <div className="min-w-0 flex-1">
                  <StepDots current={step} />
                </div>
                <span className="hidden shrink-0 text-[11px] text-text-muted sm:inline">
                  {step + 1}/{steps.length}
                </span>
                <button
                  type="button"
                  onClick={() => finish(false)}
                  className="flex shrink-0 items-center gap-1 rounded-lg px-2 py-1 text-xs text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
                >
                  Skip <X size={12} />
                </button>
              </div>

              {/* ── Step 0 : Welcome ── */}
              {step === 0 && (
                <div className="space-y-4 text-center">
                  <Sparkles size={32} strokeWidth={1.75} className="mk-ai-icon-shimmer" />
                  <div>
                    <h2 className="text-xl font-bold text-text sm:text-2xl">
                      Welcome to mokaid, {firstName}
                    </h2>
                    <p className="mx-auto mt-1.5 max-w-lg text-sm leading-relaxed text-text-secondary">
                      Your AI Workforce OS. Build a team of AI agents that work alongside you.
                    </p>
                  </div>
                  <div className="grid grid-cols-3 gap-2.5">
                    <FeatureCard
                      icon={<Bot size={16} />}
                      title="AI Agents"
                      body="Hire agents with skills. They work autonomously."
                      delay="0.05s"
                    />
                    <FeatureCard
                      icon={<FolderKanban size={16} />}
                      title="Projects & Tasks"
                      body="Brief in plain language. Track on a live kanban."
                      delay="0.15s"
                    />
                    <FeatureCard
                      icon={<Plug size={16} />}
                      title="Your Tools"
                      body="Slack, GitHub, Google — with your permission."
                      delay="0.25s"
                    />
                  </div>
                  <p className="text-[11px] text-text-muted">
                    About 2 minutes · every step is skippable
                  </p>
                  <StepActions>
                    <Button size="lg" className="w-full" onClick={() => setStep(1)}>
                      Set up my workspace <ArrowRight size={15} />
                    </Button>
                  </StepActions>
                </div>
              )}

              {/* ── Step 1 : Workspace setup (wide 2-col, no scroll target) ── */}
              {step === 1 && (
                <div className="space-y-3.5">
                  <div className="flex flex-wrap items-end justify-between gap-x-4 gap-y-1">
                    <div>
                      <h2 className="text-lg font-bold text-text sm:text-xl">
                        Set up your workspace
                      </h2>
                      <p className="mt-0.5 text-sm text-text-secondary">
                        Company context your agents will work with.
                      </p>
                    </div>
                  </div>

                  {/* Identity strip: logo + name + industry — one visual band */}
                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start">
                    <LogoDropZone
                      previewUrl={logoDisplay}
                      uploading={uploadLogo.isPending}
                      onFile={handleLogoFile}
                    />
                    <div className="min-w-0 flex-1 space-y-2.5">
                      <Field label="Company name" required>
                        <input
                          className="mk-input h-10"
                          placeholder="Acme Inc."
                          value={companyName}
                          onChange={(e) => setCompanyName(e.target.value)}
                          autoFocus
                        />
                      </Field>
                      {logoError && <p className="text-[11px] text-danger">{logoError}</p>}
                      <div>
                        <span className="mb-1.5 block text-xs font-medium text-text-secondary">
                          Industry
                        </span>
                        <div className="flex flex-wrap gap-1.5">
                          {industries.map((ind) => (
                            <button
                              key={ind}
                              type="button"
                              onClick={() => setIndustry(industry === ind ? "" : ind)}
                              className={cn(
                                "rounded-full px-2.5 py-1 text-[11px] font-medium transition-all",
                                industry === ind
                                  ? "bg-primary text-white shadow-[0_2px_10px_rgba(124,92,255,0.35)]"
                                  : "bg-surface-raised text-text-muted hover:text-text",
                              )}
                            >
                              {ind}
                            </button>
                          ))}
                        </div>
                      </div>
                    </div>
                  </div>

                  {/* Context pair — side by side fills width instead of stacking height */}
                  <div className="grid gap-3 sm:grid-cols-2">
                    <Field label="What does your company do?">
                      <Textarea
                        className="min-h-[4.5rem] resize-none sm:min-h-[5rem]"
                        placeholder="We build B2B billing software for SMBs…"
                        value={companySummary}
                        onChange={(e) => setCompanySummary(e.target.value)}
                      />
                    </Field>
                    <Field label="What should your agents help with?">
                      <Textarea
                        className="min-h-[4.5rem] resize-none sm:min-h-[5rem]"
                        placeholder="Ship features, draft marketing, research competitors…"
                        value={agentNeeds}
                        onChange={(e) => setAgentNeeds(e.target.value)}
                      />
                    </Field>
                  </div>

                  {/* Invite + actions share one row on large screens */}
                  <div className="grid items-end gap-3 lg:grid-cols-[1fr_auto]">
                    <Field label="Invite your team">
                      <div className="flex gap-2">
                        <input
                          className="mk-input h-10 flex-1"
                          placeholder="colleague@company.com"
                          value={emailDraft}
                          onChange={(e) => setEmailDraft(e.target.value)}
                          onKeyDown={(e) =>
                            e.key === "Enter" && (e.preventDefault(), addEmail())
                          }
                        />
                        <Button
                          variant="secondary"
                          size="icon"
                          onClick={addEmail}
                          aria-label="Add email"
                        >
                          <Plus size={14} />
                        </Button>
                      </div>
                      {inviteEmails.length > 0 && (
                        <div className="mt-1.5 flex flex-wrap gap-1">
                          {inviteEmails.map((email) => (
                            <span
                              key={email}
                              className="flex items-center gap-1 rounded-full bg-primary-muted px-2 py-0.5 text-[10px] text-primary-light"
                            >
                              <Mail size={9} /> {email}
                              <button
                                type="button"
                                onClick={() =>
                                  setInviteEmails((prev) => prev.filter((e) => e !== email))
                                }
                                className="hover:text-text"
                              >
                                <X size={9} />
                              </button>
                            </span>
                          ))}
                        </div>
                      )}
                    </Field>

                    <StepActions className="mt-0 shrink-0 lg:pb-0.5">
                      <Button variant="ghost" onClick={() => setStep(0)}>
                        <ArrowLeft size={14} />
                      </Button>
                      <Button variant="ghost" onClick={() => setStep(2)}>
                        Skip
                      </Button>
                      <Button
                        className="min-w-[9rem] flex-1 lg:flex-none"
                        loading={busy || inviteMember.isPending}
                        disabled={!companyName.trim()}
                        onClick={submitWorkspace}
                      >
                        Continue <ArrowRight size={14} />
                      </Button>
                    </StepActions>
                  </div>
                </div>
              )}

              {/* ── Step 2 : Integrations ── */}
              {step === 2 && (
                <div className="space-y-3.5">
                  <div>
                    <h2 className="text-lg font-bold text-text sm:text-xl">Connect your tools</h2>
                    <p className="mt-0.5 text-sm text-text-secondary">
                      Plug in tools your team already uses. Agents work with your permission.
                    </p>
                  </div>

                  {/* Email first: it unlocks the AI mail agent (sync + smart alerts). */}
                  <div className="rounded-xl border border-primary/25 bg-primary/5 p-3">
                    <div className="mb-2 flex items-center gap-2">
                      <span className="flex h-6 w-6 items-center justify-center rounded-md bg-primary/15 text-primary-light">
                        <Mail size={13} />
                      </span>
                      <div>
                        <p className="text-xs font-bold text-text">Connect your email</p>
                        <p className="text-[10px] text-text-muted">
                          Your AI agents read, analyze and alert you on important mail.
                        </p>
                      </div>
                    </div>
                    <div className="grid grid-cols-3 gap-2">
                      {(["gmail", microsoftProviderKey] as const).map((key) => {
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
                              "flex items-center gap-2 rounded-lg p-2.5 text-left transition-all",
                              connected
                                ? "bg-success-muted/40"
                                : "bg-surface-raised/70 hover:bg-surface-hover",
                            )}
                          >
                            <IntegrationLogo
                              providerKey={provider.key}
                              logoUrl={provider.logo_url}
                              name={provider.name}
                              size="sm"
                              onDark
                            />
                            <span className="min-w-0 flex-1 truncate text-xs font-semibold text-text">
                              {key === microsoftProviderKey ? "Microsoft" : provider.name}
                            </span>
                            {isConnecting ? (
                              <Loader2 size={13} className="animate-spin text-text-muted" />
                            ) : connected ? (
                              <CheckCircle2 size={15} className="shrink-0 text-success" />
                            ) : (
                              <Plus size={13} className="shrink-0 text-text-muted" />
                            )}
                          </button>
                        );
                      })}
                      <button
                        type="button"
                        disabled={imapConnected}
                        onClick={() => setImapDialogOpen(true)}
                        className={cn(
                          "flex items-center gap-2 rounded-lg p-2.5 text-left transition-all",
                          imapConnected
                            ? "bg-success-muted/40"
                            : "bg-surface-raised/70 hover:bg-surface-hover",
                        )}
                      >
                        <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-surface-raised text-text-secondary">
                          <Mail size={15} />
                        </span>
                        <span className="min-w-0 flex-1 truncate text-xs font-semibold text-text">
                          IMAP / SMTP
                        </span>
                        {imapConnected ? (
                          <CheckCircle2 size={15} className="shrink-0 text-success" />
                        ) : (
                          <Plus size={13} className="shrink-0 text-text-muted" />
                        )}
                      </button>
                    </div>
                  </div>

                  <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
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
                            "flex items-center gap-2.5 rounded-xl p-3 text-left transition-all",
                            connected
                              ? "bg-success-muted/40"
                              : "bg-surface-raised/60 hover:bg-surface-hover",
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
                            <span className="block truncate text-xs font-semibold text-text">
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
                              className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-success text-white"
                              aria-label="Connected"
                            >
                              <CheckCircle2 size={16} strokeWidth={2.25} />
                            </span>
                          ) : (
                            <Plus size={14} className="text-text-muted" />
                          )}
                        </button>
                      );
                    })}
                  </div>

                  {connectError && (
                    <p className="rounded-lg border border-danger/30 bg-danger/10 px-3 py-2 text-xs text-danger">
                      {connectError}
                    </p>
                  )}

                  {providers.length === 0 && (
                    <p className="rounded-lg bg-surface-raised/60 px-3 py-2 text-center text-xs text-text-muted">
                      Loading integrations… you can connect later from the MCP Hub.
                    </p>
                  )}

                  <StepActions>
                    <Button variant="ghost" onClick={() => setStep(1)}>
                      <ArrowLeft size={14} />
                    </Button>
                    <Button className="flex-1" onClick={() => setStep(3)}>
                      {connectedKeys.size > 0 ? "Continue" : "Skip for now"}{" "}
                      <ArrowRight size={14} />
                    </Button>
                  </StepActions>
                </div>
              )}

              {/* ── Step 3 : First agent ── */}
              {step === 3 && (
                <div className="space-y-3.5">
                  <div>
                    <h2 className="text-lg font-bold text-text sm:text-xl">
                      Choose your first agent
                    </h2>
                    <p className="mt-0.5 text-sm text-text-secondary">
                      Blank at level 1, or a level-10 specialist with domain packs loaded.
                    </p>
                  </div>

                  <div className="grid grid-cols-2 gap-2">
                    <button
                      type="button"
                      onClick={() => {
                        setAgentPath("blank");
                        setArchetypeKey("blank");
                      }}
                      className={cn(
                        "rounded-xl border px-3 py-2.5 text-left transition-all",
                        agentPath === "blank"
                          ? "border-primary bg-primary/10"
                          : "border-border bg-surface-raised/50 hover:border-primary/40",
                      )}
                    >
                      <span className="block text-xs font-semibold text-text">
                        New agent · Level 1
                      </span>
                      <span className="mt-0.5 block text-[10px] text-text-muted">
                        Free. Trains from your missions.
                      </span>
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        setAgentPath("specialist");
                        const first = recommended[0] ?? specialists[0];
                        if (first) setArchetypeKey(first.key);
                      }}
                      className={cn(
                        "rounded-xl border px-3 py-2.5 text-left transition-all",
                        agentPath === "specialist"
                          ? "border-primary bg-primary/10"
                          : "border-border bg-surface-raised/50 hover:border-primary/40",
                      )}
                    >
                      <span className="flex items-center gap-1.5 text-xs font-semibold text-text">
                        <Sparkles size={12} className="text-primary" />
                        Specialist · Level 10
                      </span>
                      <span className="mt-0.5 block text-[10px] text-text-muted">
                        {formatNumber(specialistCredits)} credits · packs preloaded
                      </span>
                    </button>
                  </div>

                  <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:gap-4">
                    <div className="relative mx-auto shrink-0 overflow-hidden rounded-xl border border-border bg-surface-raised/30 sm:mx-0">
                      <Suspense
                        fallback={
                          <div
                            className="flex items-center justify-center"
                            style={{ width: 140, height: 180 }}
                          >
                            <Avatar name={agentName || "?"} size="xl" isAi color={agentColor} />
                          </div>
                        }
                      >
                        <AgentPreview3D
                          color={agentColor}
                          name={agentName || "?"}
                          width={140}
                          height={180}
                        />
                      </Suspense>
                      {agentCreated && (
                        <span className="absolute bottom-2 right-2 flex h-6 w-6 items-center justify-center rounded-full bg-success text-white shadow-lg mk-fade-up">
                          <Check size={12} />
                        </span>
                      )}
                    </div>

                    <div className="flex min-w-0 w-full flex-1 flex-col gap-3">
                      <div className="grid gap-3 sm:grid-cols-2">
                        <Field label="Name" required>
                          <input
                            className="mk-input h-10"
                            value={agentName}
                            onChange={(e) => setAgentName(e.target.value)}
                          />
                        </Field>
                        <Field label="Color">
                          <div className="flex h-10 flex-wrap items-center gap-1.5">
                            {agentColors.map((color) => (
                              <button
                                key={color}
                                type="button"
                                onClick={() => setAgentColor(color)}
                                aria-label={`Color ${color}`}
                                className={cn(
                                  "h-7 w-7 rounded-full transition-transform",
                                  agentColor === color &&
                                    "scale-110 ring-2 ring-white/60 ring-offset-2 ring-offset-surface",
                                )}
                                style={{ backgroundColor: color }}
                              />
                            ))}
                          </div>
                        </Field>
                      </div>

                      {agentPath === "blank" ? (
                        <div className="rounded-lg bg-surface-raised/40 px-3 py-2 text-xs leading-relaxed text-text-muted">
                          <Sparkles size={11} className="mr-1 inline text-primary-light" />
                          Starts weak on purpose — specialty emerges as it completes missions.
                        </div>
                      ) : (
                        <Field
                          label="Specialist domain"
                          hint={
                            recommended.length
                              ? `Suggested: ${recommended.map((r) => r.name).join(", ")}`
                              : undefined
                          }
                        >
                          <div className="grid max-h-[9rem] gap-1.5 overflow-y-auto sm:grid-cols-2 lg:grid-cols-3">
                            {specialists.map((archetype) => {
                              const active = archetype.key === archetypeKey;
                              const suggested = recommendedKeys.has(archetype.key);
                              return (
                                <button
                                  key={archetype.key}
                                  type="button"
                                  onClick={() => setArchetypeKey(archetype.key)}
                                  className={cn(
                                    "rounded-lg border px-2.5 py-2 text-left transition-colors",
                                    active
                                      ? "border-primary bg-primary/10"
                                      : "border-border bg-surface-raised/40 hover:border-primary/40",
                                  )}
                                >
                                  <span className="flex items-center justify-between gap-1">
                                    <span className="truncate text-xs font-semibold text-text">
                                      {archetype.name}
                                    </span>
                                    {suggested && (
                                      <span className="shrink-0 rounded bg-primary/20 px-1 py-0.5 text-[9px] font-medium text-primary-light">
                                        Match
                                      </span>
                                    )}
                                  </span>
                                  <span className="mt-0.5 block text-[10px] text-text-muted line-clamp-1">
                                    {archetype.description}
                                  </span>
                                </button>
                              );
                            })}
                          </div>
                        </Field>
                      )}
                    </div>
                  </div>

                  {agentPath === "specialist" && !canAffordSpecialist && (
                    <p className="rounded-lg border border-warning/30 bg-warning/10 px-3 py-2 text-xs text-warning">
                      Need {formatNumber(specialistCredits)} credits (you have{" "}
                      {formatNumber(spendable)}).{" "}
                      <button type="button" className="underline" onClick={() => setStep(5)}>
                        Choose a plan
                      </button>{" "}
                      or continue free.
                    </p>
                  )}

                  {agentError && (
                    <p className="rounded-lg border border-danger/30 bg-danger/10 px-3 py-2 text-xs text-danger">
                      {agentError}
                    </p>
                  )}

                  <StepActions>
                    <Button variant="ghost" onClick={() => setStep(2)}>
                      <ArrowLeft size={14} />
                    </Button>
                    <Button variant="ghost" onClick={() => setStep(4)}>
                      Skip
                    </Button>
                    <Button
                      className="flex-1"
                      loading={busy}
                      disabled={
                        !agentName.trim() ||
                        agentCreated ||
                        (agentPath === "specialist" && !canAffordSpecialist)
                      }
                      onClick={submitAgent}
                    >
                      {agentCreated ? (
                        <>
                          <Check size={14} /> Created!
                        </>
                      ) : agentPath === "specialist" ? (
                        <>
                          <Coins size={14} /> Unlock {selectedArchetype?.name ?? "specialist"} ·{" "}
                          {formatNumber(specialistCredits)}
                        </>
                      ) : (
                        <>
                          <Bot size={14} /> Create {agentName || "agent"}
                        </>
                      )}
                    </Button>
                  </StepActions>
                </div>
              )}

              {/* ── Step 4 : First project ── */}
              {step === 4 && (
                <div className="mx-auto max-w-2xl space-y-3.5">
                  <div>
                    <h2 className="text-lg font-bold text-text sm:text-xl">
                      Create your first project
                    </h2>
                    <p className="mt-0.5 text-sm text-text-secondary">
                      Groups tasks, agents and files around one goal. Rename anytime.
                    </p>
                  </div>
                  <div className="grid gap-3 sm:grid-cols-2">
                    <Field label="Project name" required>
                      <input
                        className="mk-input h-10"
                        placeholder="e.g. Website launch, Q3 campaign…"
                        value={projectName}
                        onChange={(e) => setProjectName(e.target.value)}
                        autoFocus
                      />
                    </Field>
                    <Field label="What is it about?">
                      <input
                        className="mk-input h-10"
                        placeholder="One or two sentences (optional)"
                        value={projectDescription}
                        onChange={(e) => setProjectDescription(e.target.value)}
                      />
                    </Field>
                  </div>
                  <StepActions>
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
                  </StepActions>
                </div>
              )}

              {/* ── Step 5 : Choose a plan ── */}
              {step === 5 && (
                <div className="space-y-3.5">
                  <div className="flex flex-wrap items-end justify-between gap-3">
                    <div>
                      <h2 className="text-lg font-bold text-text sm:text-xl">Choose your plan</h2>
                      <p className="mt-0.5 text-sm text-text-secondary">
                        Monthly AI credits power your employees. Start free, upgrade anytime.
                      </p>
                    </div>
                    <BillingCycleToggle cycle={billingCycle} onChange={setBillingCycle} />
                  </div>

                  <PlanPicker
                    plans={onboardingPlans}
                    currentKey={currentPlanKey}
                    pendingKey={
                      planCheckout.isPending ? planCheckout.variables?.plan_key : undefined
                    }
                    onChoose={choosePlan}
                    cycle={billingCycle}
                    compact
                  />

                  <StepActions>
                    <Button variant="ghost" onClick={() => setStep(4)}>
                      <ArrowLeft size={14} />
                    </Button>
                    <Button variant="ghost" className="flex-1" onClick={() => setStep(6)}>
                      Continue with Free
                    </Button>
                  </StepActions>
                </div>
              )}

              {/* ── Step 6 : Done ── */}
              {step === 6 && (
                <div className="space-y-4 text-center">
                  <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-success-muted mk-float">
                    <PartyPopper size={24} className="text-success" />
                  </div>
                  <div>
                    <h2 className="text-xl font-bold text-text sm:text-2xl">You're all set!</h2>
                    <p className="mx-auto mt-1 max-w-md text-sm text-text-secondary">
                      Take a quick tour, or dive straight into the dashboard.
                    </p>
                  </div>

                  <div className="grid grid-cols-3 gap-2.5 text-left">
                    <div className="rounded-xl bg-surface-raised/60 p-3">
                      <Bot size={14} className="mb-1.5 text-primary-light" />
                      <p className="text-[11px] font-semibold text-text">
                        {agentCreated ? `${agentName} is ready` : "No agent yet"}
                      </p>
                      <p className="text-[10px] text-text-muted">
                        {agentCreated ? "Waiting at their desk" : "Create one anytime"}
                      </p>
                    </div>
                    <div className="rounded-xl bg-surface-raised/60 p-3">
                      <FolderKanban size={14} className="mb-1.5 text-primary-light" />
                      <p className="text-[11px] font-semibold text-text">
                        {projectCreated ? projectName : "No project yet"}
                      </p>
                      <p className="text-[10px] text-text-muted">
                        {projectCreated ? "Ready for tasks" : "Create one anytime"}
                      </p>
                    </div>
                    <div className="rounded-xl bg-surface-raised/60 p-3">
                      <Users size={14} className="mb-1.5 text-primary-light" />
                      <p className="text-[11px] font-semibold text-text">
                        {inviteEmails.length > 0
                          ? `${inviteEmails.length} invite${inviteEmails.length > 1 ? "s" : ""} sent`
                          : "Solo for now"}
                      </p>
                      <p className="text-[10px] text-text-muted">Invite from Members</p>
                    </div>
                  </div>

                  <StepActions>
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
                  </StepActions>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>

      <TranzilaCheckoutDialog
        saleUrl={checkoutUrl}
        onClose={() => setCheckoutUrl(null)}
        onComplete={handleCheckoutComplete}
      />

      <ImapConnectDialog
        open={imapDialogOpen}
        onOpenChange={setImapDialogOpen}
        onConnected={(email) =>
          toast({ tone: "success", title: "Mailbox connected", description: email })
        }
      />
    </div>
  );
}
