import { useEffect, useState } from "react";
import * as Switch from "@radix-ui/react-switch";
import { useUpdateWorkspace, useWorkspace } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { SkeletonRows } from "@/components/ui/skeleton";
import { LogoMark } from "@/components/brand/logo";

const featureToggles = [
  { key: "3d_office", label: "3D Office View", description: "Show the live 3D office on the dashboard" },
  { key: "ai_agents", label: "AI Agents", description: "Allow autonomous AI agent execution" },
  { key: "approvals", label: "Human Approvals", description: "Require approval for sensitive AI actions" },
  { key: "public_links", label: "Public Drive Links", description: "Allow sharing files via public links" },
];

function ToggleRow({
  label,
  description,
  checked,
  onCheckedChange,
}: {
  label: string;
  description: string;
  checked: boolean;
  onCheckedChange: (checked: boolean) => void;
}) {
  return (
    <div className="flex items-center justify-between gap-4 py-3">
      <div>
        <p className="text-xs font-semibold text-text">{label}</p>
        <p className="text-[11px] text-text-muted">{description}</p>
      </div>
      <Switch.Root
        checked={checked}
        onCheckedChange={onCheckedChange}
        className="relative h-5 w-9 shrink-0 rounded-full bg-surface-overlay transition-colors data-[state=checked]:bg-primary mk-focus-ring"
      >
        <Switch.Thumb className="block h-4 w-4 translate-x-0.5 rounded-full bg-white transition-transform data-[state=checked]:translate-x-[18px]" />
      </Switch.Root>
    </div>
  );
}

export function SettingsPage() {
  const { data, isLoading } = useWorkspace();
  const updateWorkspace = useUpdateWorkspace();

  const workspace = data?.data;
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [timezone, setTimezone] = useState("UTC");
  const [language, setLanguage] = useState("en");
  const [toggles, setToggles] = useState<Record<string, boolean>>({});

  useEffect(() => {
    if (workspace) {
      setName(workspace.name);
      setDescription(workspace.description ?? "");
      setTimezone(workspace.timezone);
      setLanguage(workspace.language);
      setToggles({
        "3d_office": true,
        ai_agents: true,
        approvals: true,
        public_links: false,
        ...workspace.feature_toggles,
      });
    }
  }, [workspace]);

  if (isLoading || !workspace) {
    return (
      <div className="space-y-5">
        <h1 className="text-xl font-bold text-text">Workspace Settings</h1>
        <SkeletonRows rows={5} />
      </div>
    );
  }

  const save = () => {
    updateWorkspace.mutate({
      name,
      description,
      timezone,
      language,
      feature_toggles: toggles,
    });
  };

  return (
    <div className="max-w-3xl space-y-5">
      <div>
        <h1 className="text-xl font-bold text-text">Workspace Settings</h1>
        <p className="text-xs text-text-muted">General preferences and feature toggles</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>General</CardTitle>
        </CardHeader>
        <CardBody className="space-y-4">
          <div className="flex items-center gap-4">
            <LogoMark size={56} />
            <div>
              <p className="text-sm font-semibold text-text">{workspace.name}</p>
              <p className="text-[11px] text-text-muted">workspace/{workspace.slug}</p>
            </div>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <div>
              <label htmlFor="ws-name" className="mb-1.5 block text-xs font-medium text-text-secondary">
                Workspace name
              </label>
              <input id="ws-name" className="mk-input" value={name} onChange={(e) => setName(e.target.value)} />
            </div>
            <div>
              <label htmlFor="ws-industry" className="mb-1.5 block text-xs font-medium text-text-secondary">
                Industry
              </label>
              <input id="ws-industry" className="mk-input" defaultValue={workspace.industry ?? ""} />
            </div>
          </div>

          <div>
            <label htmlFor="ws-desc" className="mb-1.5 block text-xs font-medium text-text-secondary">
              Description
            </label>
            <textarea
              id="ws-desc"
              className="mk-input min-h-20 resize-y"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
            />
          </div>
        </CardBody>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Localization</CardTitle>
        </CardHeader>
        <CardBody className="grid gap-4 sm:grid-cols-2">
          <div>
            <label htmlFor="ws-tz" className="mb-1.5 block text-xs font-medium text-text-secondary">
              Timezone
            </label>
            <select id="ws-tz" className="mk-input" value={timezone} onChange={(e) => setTimezone(e.target.value)}>
              {["UTC", "Europe/Paris", "Europe/London", "America/New_York", "Asia/Jerusalem", "Asia/Tokyo"].map(
                (tz) => (
                  <option key={tz} value={tz}>
                    {tz}
                  </option>
                ),
              )}
            </select>
          </div>
          <div>
            <label htmlFor="ws-lang" className="mb-1.5 block text-xs font-medium text-text-secondary">
              Language
            </label>
            <select id="ws-lang" className="mk-input" value={language} onChange={(e) => setLanguage(e.target.value)}>
              <option value="en">English</option>
              <option value="fr">Français</option>
              <option value="he">עברית</option>
            </select>
          </div>
        </CardBody>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>Features</CardTitle>
        </CardHeader>
        <CardBody className="divide-y divide-border">
          {featureToggles.map((feature) => (
            <ToggleRow
              key={feature.key}
              label={feature.label}
              description={feature.description}
              checked={toggles[feature.key] ?? false}
              onCheckedChange={(checked) => setToggles((prev) => ({ ...prev, [feature.key]: checked }))}
            />
          ))}
        </CardBody>
      </Card>

      <div className="flex justify-end">
        <Button onClick={save} loading={updateWorkspace.isPending}>
          Save Changes
        </Button>
      </div>
    </div>
  );
}
