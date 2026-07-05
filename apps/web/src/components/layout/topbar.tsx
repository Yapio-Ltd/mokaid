import { Bell, PanelLeft, Plus } from "lucide-react";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import { useNavigate } from "@tanstack/react-router";
import { Button } from "@/components/ui/button";
import { SearchInput } from "@/components/ui/search-input";
import { useUiStore } from "@/stores/ui-store";
import { useAuthStore } from "@/stores/auth-store";
import { useNotifications } from "@/api/hooks";
import { formatRelative } from "@/lib/format";
import { disconnect } from "@/realtime/phoenix-client";
import { Avatar } from "@/components/ui/avatar";

export function Topbar() {
  const toggleSidebar = useUiStore((s) => s.toggleSidebar);
  const user = useAuthStore((s) => s.user);
  const logout = useAuthStore((s) => s.logout);
  const navigate = useNavigate();
  const { data: notifications } = useNotifications();

  const unread = notifications?.data.filter((n) => !n.read_at).length ?? 0;

  const handleLogout = () => {
    disconnect();
    logout();
    navigate({ to: "/login" });
  };

  return (
    <header className="flex h-[60px] shrink-0 items-center gap-4 border-b border-border/60 bg-bg px-4">
      <Button variant="ghost" size="icon" onClick={toggleSidebar} aria-label="Toggle sidebar">
        <PanelLeft size={17} />
      </Button>

      <SearchInput placeholder="Search agents, tasks, projects…" className="w-80 max-w-full" />

      <div className="flex-1" />

      <Button size="sm" onClick={() => navigate({ to: "/tasks" })}>
        <Plus size={14} />
        New Task
      </Button>

      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button
            className="relative flex h-9 w-9 items-center justify-center rounded-md text-text-secondary transition-all duration-150 hover:bg-surface-hover hover:text-text active:scale-95 mk-focus-ring"
            aria-label="Notifications"
          >
            <Bell size={17} />
            {unread > 0 && (
              <span className="absolute right-1.5 top-1.5 flex h-4 min-w-4 items-center justify-center rounded-full bg-primary px-1 text-[9px] font-bold text-white">
                {unread}
              </span>
            )}
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="end"
            sideOffset={8}
            className="z-50 w-80 rounded-lg border border-border bg-surface-overlay p-2 shadow-lg"
          >
            <p className="px-2 py-1.5 text-xs font-semibold text-text">Notifications</p>
            {notifications?.data.length ? (
              notifications.data.slice(0, 8).map((n) => (
                <DropdownMenu.Item
                  key={n.id}
                  className="cursor-default rounded-md px-2 py-2 outline-none data-[highlighted]:bg-surface-hover"
                >
                  <p className="text-xs font-medium text-text">{n.title}</p>
                  <p className="text-[11px] text-text-muted">{formatRelative(n.inserted_at)}</p>
                </DropdownMenu.Item>
              ))
            ) : (
              <p className="px-2 py-6 text-center text-xs text-text-muted">No notifications yet</p>
            )}
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
            className="z-50 w-52 rounded-lg border border-border bg-surface-overlay p-1.5 shadow-lg"
          >
            <div className="border-b border-border px-2 py-2">
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
