import { Link, useRouterState } from "@tanstack/react-router";
import {
  BarChart3,
  Bot,
  Calendar,
  CheckSquare,
  CreditCard,
  FolderKanban,
  FolderOpen,
  LayoutDashboard,
  Plug,
  Settings,
  Users,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { useAuthStore } from "@/stores/auth-store";
import { useUiStore } from "@/stores/ui-store";
import { Logo } from "@/components/brand/logo";
import { Avatar } from "@/components/ui/avatar";
import { OnboardingChecklist } from "@/components/onboarding/onboarding-checklist";

const mainNav = [
  { to: "/dashboard", label: "Dashboard", icon: LayoutDashboard },
  { to: "/agents", label: "Agents", icon: Bot },
  { to: "/tasks", label: "Tasks", icon: CheckSquare },
  { to: "/projects", label: "Projects", icon: FolderKanban },
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
  index,
}: {
  to: string;
  label: string;
  icon: typeof LayoutDashboard;
  active: boolean;
  collapsed: boolean;
  index: number;
}) {
  return (
    <Link
      to={to}
      data-tour={`nav-${to.slice(1)}`}
      title={collapsed ? label : undefined}
      style={{ animationDelay: `${index * 45}ms` }}
      className={cn(
        "mk-snav group relative flex items-center gap-3 rounded-lg px-2.5 py-[7px] text-[13px] font-medium mk-focus-ring active:scale-[0.98]",
        active ? "is-active text-text" : "text-text-secondary hover:text-text",
        collapsed && "justify-center px-1.5",
      )}
    >
      {active && !collapsed && <span className="mk-snav-rail" aria-hidden />}
      <span className="mk-snav-icon" aria-hidden>
        <Icon size={16} strokeWidth={active ? 2.1 : 1.8} />
      </span>
      {!collapsed && <span className="mk-snav-label truncate">{label}</span>}
      {active && !collapsed && <span className="mk-snav-spark" aria-hidden />}
    </Link>
  );
}

export function Sidebar() {
  const collapsed = useUiStore((s) => s.sidebarCollapsed);
  const user = useAuthStore((s) => s.user);
  const workspaces = useAuthStore((s) => s.workspaces);
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const pathname = useRouterState({ select: (s) => s.location.pathname });

  const currentWorkspace = workspaces.find((w) => w.id === workspaceId);
  const roleName = currentWorkspace?.role_name ?? "Member";

  const isActive = (to: string) => pathname.startsWith(to);

  return (
    <nav
      className={cn(
        "mk-side flex h-full shrink-0 flex-col transition-[width] duration-200",
        collapsed ? "w-[68px]" : "w-60",
      )}
    >
      <div className="mk-side-aura" aria-hidden />
      <div className="mk-side-aura mk-side-aura--bottom" aria-hidden />

      <div
        className={cn(
          "relative z-10 flex h-[60px] items-center px-4",
          collapsed && "justify-center px-2",
        )}
      >
        <Link to="/dashboard" className="mk-focus-ring rounded-md">
          <Logo collapsed={collapsed} />
        </Link>
      </div>

      <div className="relative z-10 flex-1 space-y-6 overflow-y-auto px-3 py-4">
        <div className="space-y-1">
          {mainNav.map((item, i) => (
            <NavItem
              key={item.to}
              {...item}
              index={i}
              active={isActive(item.to)}
              collapsed={collapsed}
            />
          ))}
        </div>

        <div>
          {!collapsed && (
            <p className="mk-side-section mb-2 px-2.5 text-[10px] font-semibold uppercase tracking-widest text-text-muted">
              Workspace
            </p>
          )}
          <div className="space-y-1">
            {workspaceNav.map((item, i) => (
              <NavItem
                key={item.to}
                {...item}
                index={mainNav.length + i}
                active={isActive(item.to)}
                collapsed={collapsed}
              />
            ))}
          </div>
        </div>
      </div>

      <div className={cn("relative z-10 space-y-1.5 p-3", collapsed && "flex flex-col items-center")}>
        <OnboardingChecklist collapsed={collapsed} />
        <Link
          to="/profile"
          title={collapsed ? user?.full_name ?? "Profile" : undefined}
          className={cn(
            "mk-side-profile flex items-center gap-2.5 rounded-xl px-2.5 py-2 mk-focus-ring",
            isActive("/profile") && "is-active",
            collapsed && "justify-center px-1.5",
          )}
        >
          <span className="mk-side-avatar-ring shrink-0">
            <Avatar name={user?.full_name} src={user?.avatar_url} size="sm" color="#5936d1" />
          </span>
          {!collapsed && (
            <div className="min-w-0">
              <p className="truncate text-[13px] font-semibold text-text">{user?.full_name}</p>
              <p className="truncate text-[11px] text-text-muted">{roleName}</p>
            </div>
          )}
        </Link>
      </div>
    </nav>
  );
}
