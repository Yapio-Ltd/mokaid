import { lazy, Suspense, useEffect, useMemo, useState } from "react";
import { useAssets3d, useCreateAgent, type Asset3d } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { cn } from "@/lib/cn";

const AgentPreview3D = lazy(() =>
  import("@/three/agent-preview").then((m) => ({ default: m.AgentPreview3D })),
);

interface NewAgentModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated?: (agentId: string) => void;
}

const departments = [
  "Marketing",
  "Sales",
  "Engineering",
  "Design",
  "Operations",
  "Finance",
  "Support",
  "HR",
];

const DEFAULT_ACCENT = "#7c5cff";

function assetLabel(asset: Asset3d): string {
  const meta = asset.metadata as { display_name?: string } | undefined;
  return meta?.display_name || asset.slug.replace(/_/g, " ");
}

export function NewAgentModal({ open, onOpenChange, onCreated }: NewAgentModalProps) {
  const createAgent = useCreateAgent();
  const { data: characterAssets } = useAssets3d("character");

  const models = useMemo(() => characterAssets ?? [], [characterAssets]);
  const defaultAssetId = models.find((a) => a.slug === "avatar_male")?.id ?? models[0]?.id ?? "";

  const [name, setName] = useState("");
  const [roleTitle, setRoleTitle] = useState("");
  const [department, setDepartment] = useState<string | undefined>();
  const [skillsText, setSkillsText] = useState("");
  const [avatarAssetId, setAvatarAssetId] = useState("");

  useEffect(() => {
    if (!avatarAssetId && defaultAssetId) setAvatarAssetId(defaultAssetId);
  }, [avatarAssetId, defaultAssetId]);

  const reset = () => {
    setName("");
    setRoleTitle("");
    setDepartment(undefined);
    setSkillsText("");
    setAvatarAssetId(defaultAssetId);
  };

  const handleSubmit = async () => {
    if (!name.trim()) return;
    const brief = skillsText.trim();
    // Keep a short skill list for routing; full brief is stored for the AI to summarize.
    const skills = brief
      ? brief
          .split(/[,;\n]+/)
          .map((s) => s.trim())
          .filter((s) => s.length > 0 && s.length <= 60)
          .slice(0, 8)
          .map((s) => ({ name: s, level: 75 }))
      : [];

    const created = await createAgent.mutateAsync({
      display_name: name.trim(),
      role_title: roleTitle.trim() || undefined,
      department,
      kind: "ai",
      ai_enabled: true,
      status: "idle",
      presence_status: "online",
      skills: (skills.length > 0 ? skills : brief ? [{ name: "generalist", level: 70 }] : []) as never,
      capabilities: (brief ? { knowledge_brief: brief } : {}) as never,
      avatar_config: { primary_color: DEFAULT_ACCENT } as never,
      avatar_asset_id: avatarAssetId || defaultAssetId || null,
    });
    reset();
    onOpenChange(false);
    onCreated?.(created.data.id);
  };

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="New Agent"
      description="Choose a character, then give your teammate a name and role."
      className="w-[min(840px,calc(100vw-2rem))]"
      footer={
        <>
          <Button variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button
            size="sm"
            loading={createAgent.isPending}
            disabled={!name.trim()}
            onClick={handleSubmit}
          >
            Create Agent
          </Button>
        </>
      }
    >
      <div className="grid gap-8 md:grid-cols-[1fr_minmax(280px,340px)] md:gap-10">
        {/* Left — identity */}
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

          <div className="grid gap-5 sm:grid-cols-2">
            <Field label="Role">
              <input
                className="mk-input"
                placeholder="e.g. Marketing Specialist"
                value={roleTitle}
                onChange={(e) => setRoleTitle(e.target.value)}
              />
            </Field>
            <Field label="Department">
              <Select
                value={department}
                onValueChange={setDepartment}
                placeholder="Choose…"
                options={departments.map((d) => ({ value: d, label: d }))}
              />
            </Field>
          </div>

          <Field label="Type">
            <div className="flex flex-wrap gap-2">
              <button
                type="button"
                className="rounded-full bg-primary px-4 py-2 text-left text-white"
              >
                <span className="block text-xs font-semibold">AI Agent</span>
                <span className="block text-[10px] text-white/75">Fully autonomous</span>
              </button>
              <button
                type="button"
                disabled
                title="Coming soon"
                className="cursor-not-allowed rounded-full bg-surface-raised/60 px-4 py-2 text-left opacity-55"
              >
                <span className="flex items-center gap-1.5 text-xs font-semibold text-text-muted">
                  Hybrid
                  <span className="rounded bg-text-muted/15 px-1.5 py-0.5 text-[9px] font-bold uppercase tracking-wide text-text-muted">
                    Soon
                  </span>
                </span>
                <span className="block text-[10px] text-text-muted">AI + human takeover</span>
              </button>
            </div>
          </Field>

          <Field
            label="Skills & background"
            hint="Describe this teammate in a few sentences — expertise, tools, industries, working style. The AI will summarize it into a first knowledge profile for the agent."
          >
            <textarea
              className="mk-input min-h-[140px] resize-y py-2.5 leading-relaxed"
              placeholder={
                "e.g. Expert in B2B SaaS marketing with 8 years of experience. Strong at positioning, landing pages, and LinkedIn outreach. Comfortable with Notion, Figma, and HubSpot. Prefers clear briefs and ships weekly campaign drafts…"
              }
              value={skillsText}
              onChange={(e) => setSkillsText(e.target.value)}
              rows={6}
            />
          </Field>
        </div>

        {/* Right — full-body character picker */}
        <div className="space-y-3">
          <div>
            <p className="text-xs font-medium text-text-secondary">3D character</p>
            <p className="mt-0.5 text-[11px] text-text-muted">
              Full model with original colors. Click to select.
            </p>
          </div>

          {models.length === 0 ? (
            <div className="flex h-[320px] items-center justify-center rounded-xl bg-surface-raised/50 text-xs text-text-muted">
              Loading characters…
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
