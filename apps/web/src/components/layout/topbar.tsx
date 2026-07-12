import { useRef, useState } from "react";
import { Bell, PanelLeft, Plus, Volume2, VolumeX } from "lucide-react";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import * as Switch from "@radix-ui/react-switch";
import { useNavigate } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { useUiStore } from "@/stores/ui-store";
import { useAuthStore } from "@/stores/auth-store";
import { useChatStore } from "@/stores/chat-store";
import { useMarkNotificationRead, useNotifications } from "@/api/hooks";
import type { AppNotification } from "@/api/types";
import { cn } from "@/lib/cn";
import { formatRelative } from "@/lib/format";
import {
  formatNotificationBody,
  formatNotificationTitle,
  notificationCta,
  notificationTone,
} from "@/lib/notifications";
import { disconnect } from "@/realtime/phoenix-client";
import { Avatar } from "@/components/ui/avatar";
import { AgentAvatar } from "@/components/agents/agent-avatar";
import { NewTaskModal } from "@/components/modals/new-task-modal";
import { GlobalSearch } from "@/components/layout/global-search";
import { CreditBalance } from "@/components/billing/credit-balance";
import { WorkspaceProjectSwitcher } from "@/components/layout/workspace-project-switcher";
import { useActiveProjectId } from "@/stores/project-store";
import { useReviewQueueStore } from "@/stores/review-queue-store";

const TONE_DOT: Record<ReturnType<typeof notificationTone>, string> = {
  success: "bg-success",
  error: "bg-danger",
  warning: "bg-warning",
  info: "bg-primary-light",
};

const TONE_EYEBROW: Record<ReturnType<typeof notificationTone>, string> = {
  success: "text-success",
  error: "text-danger",
  warning: "text-warning",
  info: "text-primary-light",
};

export function Topbar() {
  const toggleSidebar = useUiStore((s) => s.toggleSidebar);
  const user = useAuthStore((s) => s.user);
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const logout = useAuthStore((s) => s.logout);
  const activeProjectId = useActiveProjectId(workspaceId);
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { data: notifications } = useNotifications();
  const markRead = useMarkNotificationRead();
  const selectTask = useUiStore((s) => s.selectTask);
  const soundEnabled = useChatStore((s) => s.soundEnabled);
  const setSoundEnabled = useChatStore((s) => s.setSoundEnabled);
  const [showNewTask, setShowNewTask] = useState(false);
  const markedOpenRef = useRef(false);

  const unread = notifications?.data.filter((n) => !n.read_at).length ?? 0;

  const openNotification = (n: AppNotification) => {
    if (n.resource_type === "task" && n.resource_id) {
      if (n.kind === "ai_run_completed" || n.kind === "approval_requested") {
        useReviewQueueStore.getState().enqueue(
          {
            taskId: n.resource_id,
            kind: n.kind === "approval_requested" ? "tool_approval" : "in_review",
            title: n.title?.replace(/^[^:]+:\s*/, "") || n.title || "Task",
          },
          { open: true },
        );
        return;
      }
      if (n.kind === "ai_run_failed" && n.agent?.id) {
        useChatStore.getState().openChat(n.agent.id);
        return;
      }
      selectTask(n.resource_id);
      navigate({ to: "/tasks" });
    }
  };

  const handleLogout = () => {
    disconnect();
    logout();
    navigate({ to: "/login" });
  };

  const markAllReadOnOpen = (open: boolean) => {
    if (!open) {
      markedOpenRef.current = false;
      return;
    }
    if (markedOpenRef.current) return;
    markedOpenRef.current = true;

    const unreadItems = notifications?.data.filter((n) => !n.read_at) ?? [];
    if (unreadItems.length === 0) return;

    const now = new Date().toISOString();
    queryClient.setQueriesData<{ data: AppNotification[] }>(
      { queryKey: ["notifications"] },
      (current) => {
        if (!current?.data) return current;
        return {
          ...current,
          data: current.data.map((n) => (n.read_at ? n : { ...n, read_at: now })),
        };
      },
    );

    unreadItems.forEach((n) => markRead.mutate(n.id));
  };

  return (
    <header className="flex h-[60px] shrink-0 items-center gap-4 bg-bg px-4">
      <Button variant="ghost" size="icon" onClick={toggleSidebar} aria-label="Toggle sidebar">
        <PanelLeft size={17} />
      </Button>

      <WorkspaceProjectSwitcher />

      <div className="flex-1" />

      <GlobalSearch />

      <CreditBalance />

      <div
        className="flex items-center gap-1.5 rounded-full border border-border bg-surface-raised/60 py-1 pl-2 pr-1.5"
        title={soundEnabled ? "Sounds on" : "Sounds muted"}
      >
        {soundEnabled ? (
          <Volume2 size={13} className="text-text-secondary" aria-hidden />
        ) : (
          <VolumeX size={13} className="text-text-muted" aria-hidden />
        )}
        <Switch.Root
          checked={soundEnabled}
          onCheckedChange={setSoundEnabled}
          aria-label={soundEnabled ? "Mute sounds" : "Unmute sounds"}
          className="relative h-5 w-9 shrink-0 rounded-full bg-surface-overlay transition-colors data-[state=checked]:bg-primary mk-focus-ring"
        >
          <Switch.Thumb className="block h-4 w-4 translate-x-0.5 rounded-full bg-white shadow-sm transition-transform data-[state=checked]:translate-x-[18px]" />
        </Switch.Root>
      </div>

      <Button size="sm" data-tour="new-task" onClick={() => setShowNewTask(true)}>
        <Plus size={14} />
        New Task
      </Button>
      <NewTaskModal
        open={showNewTask}
        onOpenChange={setShowNewTask}
        defaultProjectId={activeProjectId ?? undefined}
      />

      <DropdownMenu.Root onOpenChange={markAllReadOnOpen}>
        <DropdownMenu.Trigger asChild>
          <button
            className="relative flex h-9 w-9 items-center justify-center rounded-md text-text-secondary transition-all duration-150 hover:bg-surface-hover hover:text-text active:scale-95 mk-focus-ring"
            aria-label="Notifications"
          >
            <Bell size={20} strokeWidth={1.75} />
            {unread > 0 && (
              <span className="absolute -right-0.5 -top-0.5 flex h-[18px] min-w-[18px] items-center justify-center rounded-full border-2 border-bg bg-danger px-1 text-[10px] font-semibold leading-none text-white">
                {unread > 99 ? "99+" : unread}
              </span>
            )}
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="end"
            sideOffset={8}
            className="z-50 w-[380px] overflow-hidden rounded-xl border border-border bg-surface-overlay shadow-xl"
          >
            <div className="border-b border-border px-3.5 py-2.5">
              <p className="text-sm font-semibold text-text">Notifications</p>
            </div>

            <div className="max-h-[420px] overflow-y-auto p-1.5">
              {notifications?.data.length ? (
                notifications.data.slice(0, 12).map((n) => (
                  <NotificationRow
                    key={n.id}
                    notification={n}
                    onOpen={() => openNotification(n)}
                  />
                ))
              ) : (
                <div className="px-3 py-10 text-center">
                  <Bell size={22} className="mx-auto mb-2 text-text-muted opacity-50" />
                  <p className="text-xs font-medium text-text-secondary">You&apos;re all caught up</p>
                  <p className="mt-0.5 text-[11px] text-text-muted">
                    Task updates from your agents will show up here.
                  </p>
                </div>
              )}
            </div>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>

      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button
            className="mk-focus-ring rounded-full transition-transform duration-150 hover:scale-105 active:scale-95"
            aria-label="Account menu"
          >
            <Avatar name={user?.full_name} size="sm" color="#5936d1" />
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="end"
            sideOffset={8}
            className="z-50 w-52 rounded-lg bg-surface-overlay p-1.5 shadow-lg"
          >
            <div className="px-2 py-2">
              <p className="text-xs font-semibold text-text">{user?.full_name}</p>
              <p className="text-[11px] text-text-muted">{user?.email}</p>
            </div>
            <DropdownMenu.Item
              className="mt-1 cursor-pointer rounded-md px-2 py-1.5 text-xs text-text outline-none data-[highlighted]:bg-surface-hover"
              onSelect={() => navigate({ to: "/settings" })}
            >
              Workspace Settings
            </DropdownMenu.Item>
            <DropdownMenu.Item
              className="cursor-pointer rounded-md px-2 py-1.5 text-xs text-danger outline-none data-[highlighted]:bg-danger/10"
              onSelect={handleLogout}
            >
              Log out
            </DropdownMenu.Item>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
    </header>
  );
}

function NotificationRow({
  notification: n,
  onOpen,
}: {
  notification: AppNotification;
  onOpen: () => void;
}) {
  const tone = notificationTone(n.kind);
  const { eyebrow, headline } = formatNotificationTitle(n);
  const body = formatNotificationBody(n);
  const cta = notificationCta(n);
  const unread = !n.read_at;

  return (
    <DropdownMenu.Item
      onSelect={onOpen}
      className={cn(
        "cursor-pointer rounded-lg px-2.5 py-2.5 outline-none data-[highlighted]:bg-surface-hover",
        !unread && "opacity-60",
      )}
    >
      <div className="flex gap-2.5">
        <div className="relative shrink-0 pt-0.5">
          {n.agent ? (
            <AgentAvatar agent={n.agent} size="xs" showBadge={false} showRing={false} />
          ) : (
            <span className="flex h-7 w-7 items-center justify-center rounded-full bg-surface-hover text-text-muted">
              <Bell size={13} />
            </span>
          )}
          <span
            className={cn(
              "absolute -bottom-0.5 -right-0.5 h-2.5 w-2.5 rounded-full ring-2 ring-surface-overlay",
              TONE_DOT[tone],
            )}
            aria-hidden
          />
        </div>

        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-2">
            <p className={cn("text-[10px] font-semibold uppercase tracking-wide", TONE_EYEBROW[tone])}>
              {eyebrow}
            </p>
            {unread && <span className="mt-1 h-1.5 w-1.5 shrink-0 rounded-full bg-danger" />}
          </div>

          <p className="mt-0.5 truncate text-xs font-medium text-text">{headline}</p>

          {n.agent?.display_name && (
            <p className="mt-0.5 text-[11px] text-text-muted">{n.agent.display_name}</p>
          )}

          {body && (
            <p className="mt-1 line-clamp-2 text-[11px] leading-relaxed text-text-secondary">
              {body}
            </p>
          )}

          <p className="mt-1.5 flex items-center justify-between gap-2 text-[11px] text-text-muted">
            <span>{formatRelative(n.inserted_at)}</span>
            {cta && <span className="font-medium text-primary-light">{cta}</span>}
          </p>
        </div>
      </div>
    </DropdownMenu.Item>
  );
}
