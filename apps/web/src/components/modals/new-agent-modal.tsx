import { lazy, Suspense, useEffect, useMemo, useState } from "react";
import { Link } from "@tanstack/react-router";
import { Coins, Sparkles } from "lucide-react";
import {
  useAgentCatalog,
  useAssets3d,
  useBillingOverview,
  useCreateAgent,
  type Asset3d,
} from "@/api/hooks";
import { ApiError } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { cn } from "@/lib/cn";
import { formatNumber } from "@/lib/format";

const AgentPreview3D = lazy(() =>
  import("@/three/agent-preview").then((m) => ({ default: m.AgentPreview3D })),
);

interface NewAgentModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: (agentId: string) => void;
}

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

export function NewAgentModal({ open, onOpenChange, onCreated }: NewAgentModalProps) {
  const createAgent = useCreateAgent();
  const { data: catalogData } = useAgentCatalog();
  const { data: billingData } = useBillingOverview();
  const {
    data: characterAssets,
    isLoading: charactersLoading,
    isError: charactersError,
  } = useAssets3d("character");

  const models = useMemo(() => characterAssets ?? [], [characterAssets]);
  const defaultAssetId = models.find((a) => a.slug === "avatar_male")?.id ?? models[0]?.id ?? "";
  const archetypes = catalogData?.data.archetypes ?? [];
  const boosts = catalogData?.data.boosts ?? [];
  const spendable = billingData?.data.credits.spendable ?? 0;

  const [name, setName] = useState("");
  const [archetypeKey, setArchetypeKey] = useState("blank");
  const [boostKey, setBoostKey] = useState<string | null>(null);
  const [knowledgeBrief, setKnowledgeBrief] = useState("");
  const [avatarAssetId, setAvatarAssetId] = useState("");
  const [error, setError] = useState<string | null>(null);

  const selectedArchetype = archetypes.find((a) => a.key === archetypeKey) ?? archetypes[0];
  const selectedBoost = boosts.find((b) => b.key === boostKey) ?? null;
  const boostCost = selectedBoost?.credits ?? 0;
  const canAffordBoost = !selectedBoost || spendable >= boostCost;
  const isBlank = (selectedArchetype?.tier ?? selectedArchetype?.key) === "blank" || selectedArchetype?.key === "blank";
  const visibleBoosts = boosts.filter((b) => !(b.key === "boost_l10" && isBlank));

  useEffect(() => {
    if (!avatarAssetId && defaultAssetId) setAvatarAssetId(defaultAssetId);
  }, [avatarAssetId, defaultAssetId]);

  useEffect(() => {
    if (open && archetypes.length > 0 && !archetypes.some((a) => a.key === archetypeKey)) {
      setArchetypeKey(archetypes[0].key);
    }
  }, [open, archetypes, archetypeKey]);

  const reset = () => {
    setName("");
    setArchetypeKey("blank");
    setBoostKey(null);
    setKnowledgeBrief("");
    setAvatarAssetId(defaultAssetId);
    setError(null);
  };

  const handleSubmit = async () => {
    if (!name.trim() || !canAffordBoost) return;
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
      });
      reset();
      onOpenChange(false);
      onCreated?.(created.data.id);
    } catch (e) {
      if (e instanceof ApiError) {
        setError(e.message);
      } else {
        setError(e instanceof Error ? e.message : "Could not create agent.");
      }
    }
  };

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="New Agent"
      description="Pick an archetype, optionally accelerate growth with credits, then choose a character."
      className="w-[min(920px,calc(100vw-2rem))]"
      footer={
        <>
          <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            size="sm"
            loading={createAgent.isPending}
            disabled={!name.trim() || !canAffordBoost}
            onClick={handleSubmit}
          >
            Create Agent
            {boostCost > 0 ? ` · ${formatNumber(boostCost)} credits` : ""}
          </Button>
        </>
      }
    >
      <div className="grid gap-8 md:grid-cols-[1fr_minmax(280px,340px)] md:gap-10">
        <div className="space-y-6">
          <Field label="Name" required>
            <input
              className="mk-input"
              placeholder="e.g. Nova"
              value={name}
              onChange={(e) => setName(e.target.value)}
              autoFocus
            />
          </Field>

          <Field label="Archetype" hint="Seeds modest skills — specialization still emerges from missions.">
            <div className="grid gap-2 sm:grid-cols-2">
              {archetypes.map((archetype) => {
                const active = archetype.key === archetypeKey;
                return (
                  <button
                    key={archetype.key}
                    type="button"
                    onClick={() => {
                      setArchetypeKey(archetype.key);
                      if (archetype.tier === "blank" && boostKey === "boost_l10") setBoostKey(null);
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
                      <span className="block text-xs font-semibold text-text">{archetype.name}</span>
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
                  <Link to="/billing" className="underline" onClick={() => onOpenChange(false)}>
                    Buy a pack
                  </Link>
                </p>
              )}
            </div>
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

          {error && (
            <p className="rounded-lg border border-danger/30 bg-danger/10 px-3 py-2 text-xs text-danger">
              {error}
              {error.toLowerCase().includes("limit") && (
                <>
                  {" "}
                  <Link to="/billing" className="underline" onClick={() => onOpenChange(false)}>
                    Upgrade plan
                  </Link>
                </>
              )}
            </p>
          )}
        </div>

        <div className="space-y-3">
          <div>
            <p className="text-xs font-medium text-text-secondary">3D character</p>
            <p className="mt-0.5 text-[11px] text-text-muted">
              Full model with original colors. Click to select.
            </p>
          </div>

          {charactersLoading && models.length === 0 ? (
            <div className="flex h-[320px] items-center justify-center rounded-xl bg-surface-raised/50 text-xs text-text-muted">
              Loading characters…
            </div>
          ) : charactersError || models.length === 0 ? (
            <div className="flex h-[320px] flex-col items-center justify-center gap-1 rounded-xl bg-surface-raised/50 px-4 text-center text-xs text-text-muted">
              <span>No 3D characters available.</span>
              <span className="text-[11px] text-text-muted/80">
                Refresh the page or contact support if this persists.
              </span>
            </div>
          ) : (
            <div className="grid grid-cols-2 gap-3">
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
                        height: 260,
                        background:
                          "radial-gradient(ellipse at 50% 70%, #3d3858 0%, #16141f 65%, #12101a 100%)",
                      }}
                    >
                      <Suspense
                        fallback={
                          <span className="absolute inset-0 animate-pulse bg-surface-hover/30" />
                        }
                      >
                        {open && (
                          <AgentPreview3D
                            name={assetLabel(asset)}
                            color={DEFAULT_ACCENT}
                            width={150}
                            height={250}
                            cdnPath={asset.cdn_path}
                            allowTint={false}
                            animation="walking"
                          />
                        )}
                      </Suspense>
                    </span>
                    <span className="px-3 py-2.5 text-[12px] font-semibold capitalize text-text">
                      {assetLabel(asset)}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </div>
    </Dialog>
  );
}
