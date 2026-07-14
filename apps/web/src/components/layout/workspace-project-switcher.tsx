import { useState } from "react";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import {
  Check,
  ChevronsUpDown,
  CreditCard,
  FolderKanban,
  Layers,
  Pencil,
  Plus,
  Settings,
} from "lucide-react";
import { apiFetch } from "@/api/client";
import { useCreateWorkspace, useProjects } from "@/api/hooks";
import type { Workspace } from "@/api/types";
import { useAuthStore } from "@/stores/auth-store";
import { useActiveProjectId, useProjectStore } from "@/stores/project-store";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { cn } from "@/lib/cn";

const itemClass =
  "flex cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-xs text-text outline-none data-[highlighted]:bg-surface-hover";

function WorkspaceBadge({ name, className }: { name: string; className?: string }) {
  return (
    <span
      className={cn(
        "flex h-5 w-5 shrink-0 items-center justify-center rounded bg-primary-muted text-[9px] font-bold text-primary-light",
        className,
      )}
    >
      {name.slice(0, 1).toUpperCase()}
    </span>
  );
}

/**
 * Supabase/Neon-style breadcrumb switcher shown in the header:
 * [Workspace ▾] / [Project ▾]. Each workspace has its own agents, billing
 * and projects; the active project scopes task views.
 */
export function WorkspaceProjectSwitcher() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const workspaces = useAuthStore((s) => s.workspaces);
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const selectWorkspace = useAuthStore((s) => s.selectWorkspace);
  const addWorkspace = useAuthStore((s) => s.addWorkspace);
  const patchWorkspace = useAuthStore((s) => s.patchWorkspace);

  const activeProjectId = useActiveProjectId(workspaceId);
  const setActiveProject = useProjectStore((s) => s.setActiveProject);
  const { data: projectsData } = useProjects();

  const createWorkspace = useCreateWorkspace();
  const [dialog, setDialog] = useState<"create" | "rename" | null>(null);
  const [workspaceName, setWorkspaceName] = useState("");
  const [saving, setSaving] = useState(false);

  const currentWorkspace = workspaces.find((w) => w.id === workspaceId);
  const projects = projectsData?.data ?? [];
  const activeProject = projects.find((p) => p.id === activeProjectId) ?? null;

  const handleSwitchWorkspace = (id: string) => {
    if (id === workspaceId) return;
    selectWorkspace(id);
    queryClient.clear();
  };

  const handleCreateWorkspace = async () => {
    const name = workspaceName.trim();
    if (!name) return;
    setSaving(true);
    try {
      const { data } = await createWorkspace.mutateAsync({ name });
      addWorkspace({
        id: data.id,
        name: data.name,
        slug: data.slug,
        logo_url: data.logo_url,
        role_name: "Owner",
      });
      selectWorkspace(data.id);
      queryClient.clear();
      setDialog(null);
      setWorkspaceName("");
    } finally {
      setSaving(false);
    }
  };

  const handleRenameWorkspace = async () => {
    const name = workspaceName.trim();
    if (!name || !workspaceId) return;
    setSaving(true);
    try {
      await apiFetch<{ data: Workspace }>(`/api/workspaces/${workspaceId}`, {
        method: "PATCH",
        body: { name },
      });
      patchWorkspace(workspaceId, { name });
      queryClient.invalidateQueries({ queryKey: ["workspace"] });
      setDialog(null);
      setWorkspaceName("");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="flex min-w-0 items-center gap-1" data-tour="workspace-switcher">
      {/* Workspace */}
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button className="flex min-w-0 items-center gap-2 rounded-md px-2 py-1.5 transition-colors hover:bg-surface-hover mk-focus-ring">
            <WorkspaceBadge name={currentWorkspace?.name ?? "W"} />
            <span className="max-w-[140px] truncate text-xs font-semibold text-text">
              {currentWorkspace?.name ?? "Workspace"}
            </span>
            <ChevronsUpDown size={12} className="shrink-0 text-text-muted" />
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="start"
            sideOffset={6}
            className="z-50 w-64 rounded-lg bg-surface-overlay p-1.5 shadow-lg"
          >
            <p className="px-2 py-1 text-[10px] font-semibold uppercase tracking-widest text-text-muted">
              Workspaces
            </p>
            {workspaces.map((w) => (
              <DropdownMenu.Item
                key={w.id}
                onSelect={() => handleSwitchWorkspace(w.id)}
                className={itemClass}
              >
                <WorkspaceBadge name={w.name} />
                <span className="min-w-0 flex-1 truncate">{w.name}</span>
                {w.id === workspaceId && <Check size={12} className="text-primary-light" />}
              </DropdownMenu.Item>
            ))}
            <DropdownMenu.Separator className="my-1.5 h-px bg-border" />
            <DropdownMenu.Item
              onSelect={() => {
                setWorkspaceName("");
                setDialog("create");
              }}
              className={itemClass}
            >
              <Plus size={13} className="text-text-muted" /> New workspace
            </DropdownMenu.Item>
            <DropdownMenu.Item
              onSelect={() => {
                setWorkspaceName(currentWorkspace?.name ?? "");
                setDialog("rename");
              }}
              className={itemClass}
            >
              <Pencil size={13} className="text-text-muted" /> Rename workspace
            </DropdownMenu.Item>
            <DropdownMenu.Separator className="my-1.5 h-px bg-border" />
            <DropdownMenu.Item onSelect={() => navigate({ to: "/settings" })} className={itemClass}>
              <Settings size={13} className="text-text-muted" /> Workspace settings
            </DropdownMenu.Item>
            <DropdownMenu.Item onSelect={() => navigate({ to: "/billing" })} className={itemClass}>
              <CreditCard size={13} className="text-text-muted" /> Billing & plan
            </DropdownMenu.Item>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>

      <span className="select-none text-border-strong">/</span>

      {/* Project */}
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button className="flex min-w-0 items-center gap-2 rounded-md px-2 py-1.5 transition-colors hover:bg-surface-hover mk-focus-ring">
            {activeProject ? (
              <FolderKanban size={13} className="shrink-0 text-primary-light" />
            ) : (
              <Layers size={13} className="shrink-0 text-text-muted" />
            )}
            <span
              className={cn(
                "max-w-[140px] truncate text-xs font-medium",
                activeProject ? "text-text" : "text-text-secondary",
              )}
            >
              {activeProject?.name ?? "All projects"}
            </span>
            <ChevronsUpDown size={12} className="shrink-0 text-text-muted" />
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="start"
            sideOffset={6}
            className="z-50 w-64 rounded-lg bg-surface-overlay p-1.5 shadow-lg"
          >
            <p className="px-2 py-1 text-[10px] font-semibold uppercase tracking-widest text-text-muted">
              Projects
            </p>
            <DropdownMenu.Item
              onSelect={() => workspaceId && setActiveProject(workspaceId, null)}
              className={itemClass}
            >
              <Layers size={13} className="text-text-muted" />
              <span className="min-w-0 flex-1 truncate">All projects</span>
              {!activeProjectId && <Check size={12} className="text-primary-light" />}
            </DropdownMenu.Item>
            {projects.map((project) => (
              <DropdownMenu.Item
                key={project.id}
                onSelect={() => workspaceId && setActiveProject(workspaceId, project.id)}
                className={itemClass}
              >
                <FolderKanban size={13} className="text-text-muted" />
                <span className="min-w-0 flex-1 truncate">{project.name}</span>
                {project.id === activeProjectId && <Check size={12} className="text-primary-light" />}
              </DropdownMenu.Item>
            ))}
            <DropdownMenu.Separator className="my-1.5 h-px bg-border" />
            <DropdownMenu.Item onSelect={() => navigate({ to: "/projects" })} className={itemClass}>
              <Plus size={13} className="text-text-muted" /> New project
            </DropdownMenu.Item>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>

      {/* Create / rename workspace dialogs */}
      <Dialog
        open={dialog != null}
        onOpenChange={(open) => !open && setDialog(null)}
        title={dialog === "create" ? "New workspace" : "Rename workspace"}
        description={
          dialog === "create"
            ? "Each workspace has its own projects, agents and billing."
            : undefined
        }
        footer={
          <>
            <Button variant="ghost" size="sm" onClick={() => setDialog(null)}>
              Cancel
            </Button>
            <Button
              size="sm"
              loading={saving}
              disabled={!workspaceName.trim()}
              onClick={dialog === "create" ? handleCreateWorkspace : handleRenameWorkspace}
            >
              {dialog === "create" ? "Create workspace" : "Save"}
            </Button>
          </>
        }
      >
        <input
          className="mk-input"
          autoFocus
          placeholder="Workspace name"
          value={workspaceName}
          onChange={(e) => setWorkspaceName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter")
              (dialog === "create" ? handleCreateWorkspace : handleRenameWorkspace)();
          }}
        />
      </Dialog>
    </div>
  );
}
