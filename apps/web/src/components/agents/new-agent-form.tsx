import { lazy, Suspense, useEffect, useMemo, useState } from "react";
import { Link, useNavigate } from "@tanstack/react-router";
import {
  ArrowLeft,
  ArrowRight,
  Check,
  Coins,
  Sparkles,
  Zap,
} from "lucide-react";
import {
  useAgentCatalog,
  useAssets3d,
  useBillingOverview,
  useCreateAgent,
  type Asset3d,
} from "@/api/hooks";
import type { AgentAutonomyMode } from "@/api/types";
import { ApiError } from "@/api/client";
import { AutonomyModePicker } from "@/components/agents/autonomy-mode-picker";
import { Button } from "@/components/ui/button";
import { Field } from "@/components/ui/field";
import { cn } from "@/lib/cn";
import { formatNumber } from "@/lib/format";

const AgentPreview3D = lazy(() =>
  import("@/three/agent-preview").then((m) => ({ default: m.AgentPreview3D })),
);

const DEFAULT_ACCENT = "#7c5cff";

/** Archetype → preferred character slug (mirrors Assets3d.character_for_archetype/1). */
const ARCHETYPE_AVATAR_SLUG: Record<string, string> = {
  legal: "avatar_legal",
  finance: "avatar_finance",
  design: "avatar_design",
  research: "avatar_research",
  developer: "avatar_developer",
  engineering: "avatar_developer",
};

function assetLabel(asset: Asset3d): string {
  const meta = asset.metadata as { display_name?: string } | undefined;
  return meta?.display_name || asset.slug.replace(/_/g, " ");
}

const STEPS = [
  { key: "identity", label: "Identity" },
  { key: "archetype", label: "Archetype" },
  { key: "instructions", label: "Instructions" },
  { key: "autonomy", label: "Autonomy" },
  { key: "character", label: "Character" },
] as const;

type StepKey = (typeof STEPS)[number]["key"];

export function NewAgentForm() {
  const navigate = useNavigate();
  const createAgent = useCreateAgent();
  const { data: catalogData } = useAgentCatalog();
  const { data: billingData } = useBillingOverview();
  const {
    data: characterAssets,
    isLoading: charactersLoading,
    isError: charactersError,
    error: charactersErr,
    refetch: refetchCharacters,
    isFetching: charactersFetching,
  } = useAssets3d("character");

  const models = useMemo(() => characterAssets ?? [], [characterAssets]);
  const defaultAssetId = models.find((a) => a.slug === "avatar_male")?.id ?? models[0]?.id ?? "";
  const archetypes = catalogData?.data.archetypes ?? [];
  const boosts = catalogData?.data.boosts ?? [];
  const spendable = billingData?.data.credits.spendable ?? 0;

  const [step, setStep] = useState<StepKey>("identity");
  const [name, setName] = useState("");
  const [archetypeKey, setArchetypeKey] = useState("blank");
  const [boostKey, setBoostKey] = useState<string | null>(null);
  const [knowledgeBrief, setKnowledgeBrief] = useState("");
  const [instructions, setInstructions] = useState("");
  const [modelQuality, setModelQuality] = useState<"fast" | "smart">("smart");
  const [autonomyMode, setAutonomyMode] = useState<AgentAutonomyMode>("balanced");
  const [avatarAssetId, setAvatarAssetId] = useState("");
  const [error, setError] = useState<string | null>(null);

  const selectedArchetype = archetypes.find((a) => a.key === archetypeKey) ?? archetypes[0];
  const selectedBoost = boosts.find((b) => b.key === boostKey) ?? null;
  const boostCost = selectedBoost?.credits ?? 0;
  const canAffordBoost = !selectedBoost || spendable >= boostCost;
  const isBlank =
    (selectedArchetype?.tier ?? selectedArchetype?.key) === "blank" ||
    selectedArchetype?.key === "blank";
  const visibleBoosts = boosts.filter((b) => !(b.key === "boost_l10" && isBlank));

  const selectedAsset =
    models.find((a) => a.id === (avatarAssetId || defaultAssetId)) ?? models[0] ?? null;

  useEffect(() => {
    if (!avatarAssetId && defaultAssetId) setAvatarAssetId(defaultAssetId);
  }, [avatarAssetId, defaultAssetId]);

  useEffect(() => {
    if (archetypes.length > 0 && !archetypes.some((a) => a.key === archetypeKey)) {
      setArchetypeKey(archetypes[0].key);
    }
  }, [archetypes, archetypeKey]);

  const stepIndex = STEPS.findIndex((s) => s.key === step);
  const isLast = stepIndex === STEPS.length - 1;

  const stepValid = (key: StepKey): boolean => {
    switch (key) {
      case "identity":
        return name.trim().length > 0;
      case "archetype":
        return canAffordBoost;
      default:
        return true;
    }
  };

  const canAdvance = stepValid(step);
  const canSubmit = STEPS.every((s) => stepValid(s.key));

  const goNext = () => {
    if (!canAdvance) return;
    if (!isLast) setStep(STEPS[stepIndex + 1].key);
  };
  const goBack = () => {
    if (stepIndex > 0) setStep(STEPS[stepIndex - 1].key);
  };

  const handleSubmit = async () => {
    if (!canSubmit) return;
    if (boostKey === "boost_l10" && isBlank) {
      setError("Level-10 specialist boost requires a domain archetype.");
      return;
    }
    setError(null);
    try {
      const created = await createAgent.mutateAsync({
        display_name: name.trim(),
        kind: "ai",
        archetype_key: archetypeKey,
        boost_key: boostKey,
        knowledge_brief: knowledgeBrief.trim() || undefined,
        role_title: selectedArchetype?.role_title,
        department: selectedArchetype?.department,
        avatar_config: { primary_color: DEFAULT_ACCENT },
        avatar_asset_id: avatarAssetId || defaultAssetId || null,
        instructions: instructions.trim() || undefined,
        model_quality: modelQuality,
        autonomy_mode: autonomyMode,
      });

      if (boostKey) {
        void navigate({
          to: "/agents/$agentId/training",
          params: { agentId: created.data.id },
        });
      } else {
        void navigate({ to: "/agents" });
      }
    } catch (e) {
      if (e instanceof ApiError) {
        setError(e.message);
      } else {
        setError(e instanceof Error ? e.message : "Could not create agent.");
      }
    }
  };

  return (
    <div className="mx-auto w-full max-w-6xl space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="space-y-2">
          <Link
            to="/agents"
            className="inline-flex items-center gap-1.5 text-xs font-medium text-text-muted transition-colors hover:text-text"
          >
            <ArrowLeft size={13} /> Back to agents
          </Link>
          <div className="mk-page-head">
            <h1 className="mk-page-title text-xl font-bold tracking-tight text-text">New Agent</h1>
            <p className="mt-1 text-xs text-text-muted">
              Build your AI employee step by step — everything stays editable in its profile.
            </p>
          </div>
        </div>
        <Button variant="ghost" size="sm" onClick={() => void navigate({ to: "/agents" })}>
          Cancel
        </Button>
      </div>

      {/* Step indicator */}
      <div className="flex flex-wrap items-center gap-1.5">
        {STEPS.map((s, i) => {
          const active = s.key === step;
          const done = i < stepIndex;
          return (
            <button
              key={s.key}
              type="button"
              onClick={() => {
                // Free navigation to visited/earlier steps only.
                if (i <= stepIndex) setStep(s.key);
              }}
              className={cn(
                "flex items-center gap-1.5 rounded-full border px-3 py-1.5 text-[11px] font-medium transition-colors",
                active
                  ? "border-primary bg-primary/10 text-primary-light"
                  : done
                    ? "border-success/40 bg-success/10 text-success"
                    : "border-border bg-surface-raised/40 text-text-muted",
                i > stepIndex && "cursor-default",
              )}
            >
              <span
                className={cn(
                  "flex h-4 w-4 items-center justify-center rounded-full text-[9px] font-bold",
                  active
                    ? "bg-primary text-white"
                    : done
                      ? "bg-success text-white"
                      : "bg-surface text-text-muted",
                )}
              >
                {done ? <Check size={9} /> : i + 1}
              </span>
              {s.label}
            </button>
          );
        })}
      </div>

      <div className="grid gap-8 rounded-2xl border border-border bg-surface/60 p-5 md:grid-cols-[1fr_minmax(260px,300px)] md:gap-10 md:p-8">
        {/* Left: current step */}
        <div className="space-y-6">
          {step === "identity" && (
            <>
              <Field label="Name" required>
                <input
                  className="mk-input"
                  placeholder="e.g. Nova"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  autoFocus
                />
              </Field>

              <Field
                label="Background (optional)"
                hint="Stored as private context for this agent — not used to forge skill levels."
              >
                <textarea
                  className="mk-input min-h-[100px] resize-y py-2.5 leading-relaxed"
                  placeholder="e.g. Prefer concise briefs, ship weekly drafts, strong B2B SaaS intuition…"
                  value={knowledgeBrief}
                  onChange={(e) => setKnowledgeBrief(e.target.value)}
                  rows={4}
                />
              </Field>
            </>
          )}

          {step === "archetype" && (
            <>
              <Field
                label="Archetype"
                hint="Seeds modest skills — specialization still emerges from missions."
              >
                <div className="grid gap-2 sm:grid-cols-2">
                  {archetypes.map((archetype) => {
                    const active = archetype.key === archetypeKey;
                    return (
                      <button
                        key={archetype.key}
                        type="button"
                        onClick={() => {
                          setArchetypeKey(archetype.key);
                          if (archetype.tier === "blank" && boostKey === "boost_l10")
                            setBoostKey(null);
                          const preferredSlug = ARCHETYPE_AVATAR_SLUG[archetype.key];
                          const preferred = preferredSlug
                            ? models.find((a) => a.slug === preferredSlug)
                            : undefined;
                          if (preferred) setAvatarAssetId(preferred.id);
                        }}
                        className={cn(
                          "rounded-xl border px-3 py-2.5 text-left transition-colors",
                          active
                            ? "border-primary bg-primary/10"
                            : "border-border bg-surface-raised/40 hover:border-primary/40",
                        )}
                      >
                        <span className="flex items-center justify-between gap-2">
                          <span className="block text-xs font-semibold text-text">
                            {archetype.name}
                          </span>
                          {archetype.tier === "specialist" && (
                            <span className="rounded bg-primary/15 px-1.5 py-0.5 text-[9px] text-primary-light">
                              L10 pack
                            </span>
                          )}
                        </span>
                        <span className="mt-0.5 block text-[10px] text-text-muted">
                          {archetype.description}
                        </span>
                        <span className="mt-1.5 flex flex-wrap gap-1">
                          {archetype.skills.slice(0, 3).map((skill) => (
                            <span
                              key={skill.name}
                              className="rounded bg-surface px-1.5 py-0.5 text-[9px] text-text-secondary"
                            >
                              {skill.name} {skill.level}
                            </span>
                          ))}
                          {(archetype.corpus_doc_count ?? 0) > 0 && (
                            <span className="rounded bg-surface px-1.5 py-0.5 text-[9px] text-text-secondary">
                              {archetype.skill_count ?? archetype.corpus_doc_count} skills
                            </span>
                          )}
                        </span>
                      </button>
                    );
                  })}
                </div>
              </Field>

              <Field
                label="Head start (optional)"
                hint={`Balance: ${formatNumber(spendable)} credits`}
              >
                <div className="space-y-2">
                  <button
                    type="button"
                    onClick={() => setBoostKey(null)}
                    className={cn(
                      "flex w-full items-center justify-between rounded-xl border px-3 py-2.5 text-left",
                      boostKey == null
                        ? "border-primary bg-primary/10"
                        : "border-border bg-surface-raised/40",
                    )}
                  >
                    <span>
                      <span className="block text-xs font-semibold text-text">Start at level 1</span>
                      <span className="text-[10px] text-text-muted">Free — learn from missions</span>
                    </span>
                    <span className="text-[10px] font-semibold text-success">0 credits</span>
                  </button>
                  {visibleBoosts.map((boost) => {
                    const active = boostKey === boost.key;
                    const affordable = spendable >= boost.credits;
                    return (
                      <button
                        key={boost.key}
                        type="button"
                        disabled={!affordable}
                        onClick={() => setBoostKey(boost.key)}
                        className={cn(
                          "flex w-full items-center justify-between rounded-xl border px-3 py-2.5 text-left",
                          active
                            ? "border-primary bg-primary/10"
                            : "border-border bg-surface-raised/40",
                          !affordable && "cursor-not-allowed opacity-50",
                        )}
                      >
                        <span>
                          <span className="flex items-center gap-1.5 text-xs font-semibold text-text">
                            <Sparkles size={12} className="text-primary" />
                            {boost.name}
                          </span>
                          <span className="text-[10px] text-text-muted">{boost.description}</span>
                        </span>
                        <span className="flex items-center gap-1 text-[10px] font-semibold text-text-secondary">
                          <Coins size={11} />
                          {formatNumber(boost.credits)}
                        </span>
                      </button>
                    );
                  })}
                  {!canAffordBoost && (
                    <p className="text-[11px] text-warning">
                      Not enough credits.{" "}
                      <Link to="/billing" className="underline">
                        Buy a pack
                      </Link>
                    </p>
                  )}
                </div>
              </Field>
            </>
          )}

          {step === "instructions" && (
            <>
              <Field
                label="Instructions (optional)"
                hint="Standing directives followed on every mission and chat — tone, format, priorities, hard rules."
              >
                <textarea
                  className="mk-input min-h-[140px] resize-y py-2.5 leading-relaxed"
                  placeholder={`e.g. Always write in French. Keep reports under two pages.\nNever contact clients directly — draft, don't send.`}
                  value={instructions}
                  onChange={(e) => setInstructions(e.target.value)}
                  maxLength={4000}
                  rows={6}
                  autoFocus
                />
              </Field>

              <Field label="Model" hint="Which model tier runs this agent's missions.">
                <div className="grid gap-2 sm:grid-cols-2">
                  {(
                    [
                      {
                        value: "smart",
                        label: "Smart",
                        hint: "Best quality for complex, multi-step missions.",
                        icon: Sparkles,
                      },
                      {
                        value: "fast",
                        label: "Fast",
                        hint: "Quicker and cheaper for routine, repetitive work.",
                        icon: Zap,
                      },
                    ] as const
                  ).map(({ value, label, hint, icon: Icon }) => {
                    const active = modelQuality === value;
                    return (
                      <button
                        key={value}
                        type="button"
                        onClick={() => setModelQuality(value)}
                        className={cn(
                          "rounded-xl border px-3 py-3 text-left transition-colors",
                          active
                            ? "border-primary bg-primary/10"
                            : "border-border bg-surface-raised/40 hover:border-primary/40",
                        )}
                      >
                        <span
                          className={cn(
                            "flex items-center gap-1.5 text-xs font-semibold",
                            active ? "text-primary-light" : "text-text",
                          )}
                        >
                          <Icon size={13} />
                          {label}
                          {active && <Check size={11} />}
                        </span>
                        <span className="mt-0.5 block text-[10px] text-text-muted">{hint}</span>
                      </button>
                    );
                  })}
                </div>
              </Field>
            </>
          )}

          {step === "autonomy" && (
            <Field
              label="Autonomy"
              hint="How much this agent does on its own before pausing for your approval. You can refine with per-tool rules later."
            >
              <AutonomyModePicker value={autonomyMode} onChange={setAutonomyMode} />
            </Field>
          )}

          {step === "character" && (
            <Field label="3D character" hint="Full model with original colors. Click to select.">
              {charactersLoading && models.length === 0 ? (
                <div className="flex h-[320px] items-center justify-center rounded-xl bg-surface-raised/50 text-xs text-text-muted">
                  Loading characters…
                </div>
              ) : charactersError || models.length === 0 ? (
                <div className="flex h-[320px] flex-col items-center justify-center gap-2 rounded-xl bg-surface-raised/50 px-4 text-center text-xs text-text-muted">
                  <span>No 3D characters available.</span>
                  {charactersError && (
                    <span className="text-[11px] text-danger">
                      {(charactersErr as Error)?.message || "Failed to load characters."}
                    </span>
                  )}
                  <span className="text-[11px] text-text-muted/80">
                    The catalog may not be seeded yet in this environment.
                  </span>
                  <Button
                    type="button"
                    size="sm"
                    variant="secondary"
                    loading={charactersFetching}
                    onClick={() => refetchCharacters()}
                  >
                    Retry
                  </Button>
                </div>
              ) : (
                <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
                  {models.map((asset) => {
                    const selected = asset.id === (avatarAssetId || defaultAssetId);
                    return (
                      <button
                        key={asset.id}
                        type="button"
                        onClick={() => setAvatarAssetId(asset.id)}
                        className={cn(
                          "group flex flex-col overflow-hidden rounded-xl border text-left transition-all",
                          selected
                            ? "border-primary/70 bg-primary-muted/25 shadow-[0_0_0_1px_rgba(124,92,255,0.25)]"
                            : "border-border bg-surface-raised/40 hover:border-border-strong",
                        )}
                      >
                        <span
                          className="relative flex w-full items-end justify-center overflow-hidden"
                          style={{
                            height: 180,
                            background:
                              "radial-gradient(ellipse at 50% 70%, #3d3858 0%, #16141f 65%, #12101a 100%)",
                          }}
                        >
                          <Suspense
                            fallback={
                              <span className="absolute inset-0 animate-pulse bg-surface-hover/30" />
                            }
                          >
                            <AgentPreview3D
                              name={assetLabel(asset)}
                              color={DEFAULT_ACCENT}
                              width={110}
                              height={170}
                              cdnPath={asset.cdn_path}
                              allowTint={false}
                              animation="walking"
                            />
                          </Suspense>
                        </span>
                        <span className="px-3 py-2 text-[11px] font-semibold capitalize text-text">
                          {assetLabel(asset)}
                        </span>
                      </button>
                    );
                  })}
                </div>
              )}
            </Field>
          )}

          {error && (
            <p className="rounded-lg border border-danger/30 bg-danger/10 px-3 py-2 text-xs text-danger">
              {error}
              {error.toLowerCase().includes("limit") && (
                <>
                  {" "}
                  <Link to="/billing" className="underline">
                    Upgrade plan
                  </Link>
                </>
              )}
            </p>
          )}

          {/* Step navigation */}
          <div className="flex items-center justify-between border-t border-border/60 pt-4">
            <Button variant="ghost" size="sm" disabled={stepIndex === 0} onClick={goBack}>
              <ArrowLeft size={13} /> Back
            </Button>
            {isLast ? (
              <Button
                size="sm"
                loading={createAgent.isPending}
                disabled={!canSubmit}
                onClick={handleSubmit}
                data-tour="create-agent"
              >
                Create Agent
                {boostCost > 0 ? ` · ${formatNumber(boostCost)} credits` : ""}
              </Button>
            ) : (
              <Button size="sm" disabled={!canAdvance} onClick={goNext}>
                Next <ArrowRight size={13} />
              </Button>
            )}
          </div>
        </div>

        {/* Right: persistent live preview */}
        <div className="space-y-3">
          <div>
            <p className="text-xs font-medium text-text-secondary">Live preview</p>
            <p className="mt-0.5 text-[11px] text-text-muted">
              Your future employee, updated as you build.
            </p>
          </div>

          <div
            className="relative flex items-end justify-center overflow-hidden rounded-xl"
            style={{
              height: 300,
              background:
                "radial-gradient(ellipse at 50% 70%, #3d3858 0%, #16141f 65%, #12101a 100%)",
            }}
          >
            {selectedAsset ? (
              <Suspense
                fallback={<span className="absolute inset-0 animate-pulse bg-surface-hover/30" />}
              >
                <AgentPreview3D
                  name={name.trim() || assetLabel(selectedAsset)}
                  color={DEFAULT_ACCENT}
                  width={170}
                  height={290}
                  cdnPath={selectedAsset.cdn_path}
                  allowTint={false}
                  animation="walking"
                />
              </Suspense>
            ) : (
              <span className="flex h-full items-center justify-center text-xs text-text-muted">
                Loading preview…
              </span>
            )}
          </div>

          {/* Build summary */}
          <div className="space-y-1 rounded-xl border border-border/60 bg-surface-raised/40 px-4 py-3">
            <SummaryRow label="Name" value={name.trim() || "—"} />
            <SummaryRow label="Archetype" value={selectedArchetype?.name ?? "—"} />
            <SummaryRow
              label="Head start"
              value={selectedBoost ? `${selectedBoost.name} · ${formatNumber(boostCost)} cr` : "Level 1 (free)"}
            />
            <SummaryRow label="Model" value={modelQuality === "fast" ? "Fast" : "Smart"} />
            <SummaryRow
              label="Autonomy"
              value={
                autonomyMode === "supervised"
                  ? "Supervised"
                  : autonomyMode === "autonomous"
                    ? "Autonomous"
                    : "Balanced"
              }
            />
            <SummaryRow
              label="Instructions"
              value={instructions.trim() ? `${instructions.trim().length} chars` : "None"}
            />
          </div>
        </div>
      </div>
    </div>
  );
}

function SummaryRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3 py-1">
      <span className="text-[11px] text-text-muted">{label}</span>
      <span className="min-w-0 truncate text-[11px] font-medium text-text">{value}</span>
    </div>
  );
}
