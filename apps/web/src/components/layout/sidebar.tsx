import { Link, useRouterState } from "@tanstack/react-router";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import {
  BarChart3,
  Bot,
  Calendar,
  Check,
  CheckSquare,
  ChevronsUpDown,
  CreditCard,
  FolderKanban,
  FolderOpen,
  LayoutDashboard,
  Library,
  Plug,
  Settings,
  Users,
} from "lucide-react";
import { useQueryClient } from "@tanstack/react-query";
import { cn } from "@/lib/cn";
import { useAuthStore } from "@/stores/auth-store";
import { useUiStore } from "@/stores/ui-store";
import { Logo } from "@/components/brand/logo";
import { Avatar } from "@/components/ui/avatar";

const mainNav = [
  { to: "/dashboard", label: "Dashboard", icon: LayoutDashboard },
  { to: "/agents", label: "Agents", icon: Bot },
  { to: "/tasks", label: "Tasks", icon: CheckSquare },
  { to: "/projects", label: "Projects", icon: FolderKanban },
  { to: "/knowledge", label: "Knowledge", icon: Library },
  { to: "/drive", label: "Drive", icon: FolderOpen },
  { to: "/calendar", label: "Calendar", icon: Calendar },
  { to: "/analytics", label: "Analytics", icon: BarChart3 },
];

const workspaceNav = [
  { to: "/settings", label: "Workspace Settings", icon: Settings },
  { to: "/members", label: "Members", icon: Users },
  { to: "/integrations", label: "MCP Hub", icon: Plug },
  { to: "/billing", label: "Billing", icon: CreditCard },
];

function NavItem({
  to,
  label,
  icon: Icon,
  active,
  collapsed,
}: {
  to: string;
  label: string;
  icon: typeof LayoutDashboard;
  active: boolean;
  collapsed: boolean;
}) {
  return (
    <Link
      to={to}
      data-tour={`nav-${to.slice(1)}`}
      title={collapsed ? label : undefined}
      className={cn(
        "group relative flex items-center gap-3 rounded-md px-3 py-2 text-[13px] font-medium transition-all duration-150 mk-focus-ring active:scale-[0.98]",
        active
          ? "bg-primary-muted text-primary-light"
          : "text-text-secondary hover:bg-surface-hover hover:text-text",
        collapsed && "justify-center px-2",
      )}
    >
      {active && !collapsed && (
        <span className="absolute left-0 top-1/2 h-4 w-0.5 -translate-y-1/2 rounded-full bg-primary" aria-hidden />
      )}
      <Icon
        size={17}
        className={cn(
          "transition-transform duration-150 group-hover:scale-105",
          active ? "text-primary-light" : "text-text-muted group-hover:text-text",
        )}
      />
      {!collapsed && <span className="truncate">{label}</span>}
    </Link>
  );
}

export function Sidebar() {
  const collapsed = useUiStore((s) => s.sidebarCollapsed);
  const user = useAuthStore((s) => s.user);
  const workspaces = useAuthStore((s) => s.workspaces);
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const selectWorkspace = useAuthStore((s) => s.selectWorkspace);
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const queryClient = useQueryClient();

  const currentWorkspace = workspaces.find((w) => w.id === workspaceId);
  const roleName = currentWorkspace?.role_name ?? "Member";

  const handleSwitchWorkspace = (id: string) => {
    if (id === workspaceId) return;
    selectWorkspace(id);
    queryClient.clear();
  };

  const isActive = (to: string) => pathname.startsWith(to);

  return (
    <nav
      className={cn(
        "flex h-full shrink-0 flex-col bg-bg-deep transition-[width] duration-200",
        collapsed ? "w-[68px]" : "w-60",
      )}
    >
      <div className={cn("flex h-[60px] items-center px-4", collapsed && "justify-center px-2")}>
        <Link to="/dashboard" className="mk-focus-ring rounded-md">
          <Logo collapsed={collapsed} />
        </Link>
      </div>

      {!collapsed && workspaces.length > 0 && (
        <div className="px-3 pb-2">
          <DropdownMenu.Root>
            <DropdownMenu.Trigger asChild>
              <button className="flex w-full items-center gap-2 rounded-md border border-border bg-surface px-2.5 py-2 text-left transition-colors hover:border-border-strong mk-focus-ring">
                <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded bg-primary-muted text-[10px] font-bold text-primary-light">
                  {(currentWorkspace?.name ?? "W").slice(0, 1).toUpperCase()}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-xs font-semibold text-text">
                    {currentWorkspace?.name ?? "Workspace"}
                  </span>
                </span>
                <ChevronsUpDown size={13} className="shrink-0 text-text-muted" />
              </button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content
                align="start"
                sideOffset={6}
                className="z-50 w-56 rounded-lg border border-border bg-surface-overlay p-1.5 shadow-lg"
              >
                <p className="px-2 py-1 text-[10px] font-semibold uppercase tracking-widest text-text-muted">
                  Workspaces
                </p>
                {workspaces.map((w) => (
                  <DropdownMenu.Item
                    key={w.id}
                    onSelect={() => handleSwitchWorkspace(w.id)}
                    className="flex cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-xs text-text outline-none data-[highlighted]:bg-surface-hover"
                  >
                    <span className="min-w-0 flex-1 truncate">{w.name}</span>
                    {w.id === workspaceId && <Check size={12} className="text-primary-light" />}
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
        </div>
      )}

      <div className="flex-1 space-y-6 overflow-y-auto px-3 py-4">
        <div className="space-y-0.5">
          {mainNav.map((item) => (
            <NavItem key={item.to} {...item} active={isActive(item.to)} collapsed={collapsed} />
          ))}
        </div>

        <div>
          {!collapsed && (
            <p className="mb-1.5 px-3 text-[10px] font-semibold uppercase tracking-widest text-text-muted">
              Workspace
            </p>
          )}
          <div className="space-y-0.5">
            {workspaceNav.map((item) => (
              <NavItem key={item.to} {...item} active={isActive(item.to)} collapsed={collapsed} />
            ))}
          </div>
        </div>
      </div>

      <div className={cn("p-3", collapsed && "flex justify-center")}>
        <div className={cn("flex items-center gap-2.5", collapsed && "justify-center")}>
          <Avatar name={user?.full_name} size="sm" color="#5936d1" />
          {!collapsed && (
            <div className="min-w-0">
              <p className="truncate text-[13px] font-semibold text-text">{user?.full_name}</p>
              <p className="truncate text-[11px] text-text-muted">{roleName}</p>
            </div>
          )}
        </div>
      </div>
    </nav>
  );
}
