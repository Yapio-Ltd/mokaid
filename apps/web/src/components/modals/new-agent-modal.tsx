import { useState } from "react";
import { useCreateAgent } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";
import { Select } from "@/components/ui/select";
import { cn } from "@/lib/cn";

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

const agentColors = ["#7c5cff", "#60a5fa", "#34d399", "#fbbf24", "#f472b6", "#22d3ee", "#f87171"];

export function NewAgentModal({ open, onOpenChange, onCreated }: NewAgentModalProps) {
  const createAgent = useCreateAgent();

  const [name, setName] = useState("");
  const [roleTitle, setRoleTitle] = useState("");
  const [department, setDepartment] = useState<string | undefined>();
  const [kind, setKind] = useState<"ai" | "hybrid">("ai");
  const [skillsText, setSkillsText] = useState("");
  const [color, setColor] = useState(agentColors[0]);

  const reset = () => {
    setName("");
    setRoleTitle("");
    setDepartment(undefined);
    setKind("ai");
    setSkillsText("");
    setColor(agentColors[0]);
  };

  const handleSubmit = async () => {
    if (!name.trim()) return;
    const skills = skillsText
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => ({ name: s, level: 80 }));

    const created = await createAgent.mutateAsync({
      display_name: name.trim(),
      role_title: roleTitle.trim() || undefined,
      department,
      kind,
      ai_enabled: true,
      status: "active",
      presence_status: "online",
      skills: skills as never,
      avatar_config: { primary_color: color } as never,
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
      description="Create an AI teammate and give it a role."
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
      <div className="space-y-4">
        <Field label="Name" required>
          <input
            className="mk-input"
            placeholder="e.g. Nova"
            value={name}
            onChange={(e) => setName(e.target.value)}
            autoFocus
          />
        </Field>
        <div className="grid grid-cols-2 gap-3">
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
          <div className="grid grid-cols-2 gap-2">
            <button
              type="button"
              onClick={() => setKind("ai")}
              className={cn(
                "rounded-md border px-3 py-2.5 text-left transition-colors",
                kind === "ai"
                  ? "border-primary/50 bg-primary-muted/40"
                  : "border-border hover:border-border-strong",
              )}
            >
              <p className="text-xs font-semibold text-text">AI Agent</p>
              <p className="text-[10px] text-text-muted">Fully autonomous</p>
            </button>
            <button
              type="button"
              onClick={() => setKind("hybrid")}
              className={cn(
                "rounded-md border px-3 py-2.5 text-left transition-colors",
                kind === "hybrid"
                  ? "border-primary/50 bg-primary-muted/40"
                  : "border-border hover:border-border-strong",
              )}
            >
              <p className="text-xs font-semibold text-text">Hybrid</p>
              <p className="text-[10px] text-text-muted">AI + human takeover</p>
            </button>
          </div>
        </Field>
        <Field label="Skills" hint="Comma-separated, e.g. copywriting, research, reporting">
          <input
            className="mk-input"
            placeholder="copywriting, research…"
            value={skillsText}
            onChange={(e) => setSkillsText(e.target.value)}
          />
        </Field>
        <Field label="Avatar color">
          <div className="flex gap-2">
            {agentColors.map((c) => (
              <button
                key={c}
                type="button"
                onClick={() => setColor(c)}
                aria-label={`Color ${c}`}
                className={cn(
                  "h-7 w-7 rounded-full transition-transform",
                  color === c && "scale-110 ring-2 ring-white/70 ring-offset-2 ring-offset-surface",
                )}
                style={{ backgroundColor: c }}
              />
            ))}
          </div>
        </Field>
      </div>
    </Dialog>
  );
}
