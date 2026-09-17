import { useEffect, useRef, useState } from "react";
import { Link } from "@tanstack/react-router";
import * as DropdownMenu from "@radix-ui/react-dropdown-menu";
import {
  Activity,
  ArrowRight,
  BookOpen,
  UserRoundCog,
  CalendarDays,
  ListTodo,
  CreditCard,
  Folder,
  FolderKanban,
  House,
  Mail,
  MoreHorizontal,
  Plug,
  Settings,
  Users,
  X,
} from "lucide-react";
import { LogoMark } from "@/components/brand/logo";
import { Avatar } from "@/components/ui/avatar";
import { useAuthStore } from "@/stores/auth-store";
import { useUiStore } from "@/stores/ui-store";
import { WorkspaceProjectSwitcher } from "./workspace-project-switcher";
import { Topbar } from "./topbar";
import "./workforce-shell.css";

const workforceNav = [
  { to: "/dashboard", label: "Office", icon: House },
  { to: "/agents", label: "Agents", icon: UserRoundCog },
  { to: "/tasks", label: "Tasks", icon: ListTodo },
  { to: "/projects", label: "Projects", icon: FolderKanban },
  { to: "/knowledge", label: "Knowledge", icon: BookOpen },
  { to: "/drive", label: "Files", icon: Folder },
  { to: "/calendar", label: "Calendar", icon: CalendarDays },
  { to: "/mail", label: "Mail", icon: Mail },
  { to: "/analytics", label: "Analytics", icon: Activity },
  { to: "/settings", label: "Settings", icon: Settings },
];

const workspaceLinks = [
  { to: "/profile", label: "Your profile", icon: Users },
  { to: "/members", label: "Members", icon: Users },
  { to: "/integrations", label: "Integrations", icon: Plug },
  { to: "/billing", label: "Billing & credits", icon: CreditCard },
];

/** The Agents surface keeps the existing workspace and account actions. */
export function WorkforceSidebar() {
  const sidebarRef = useRef<HTMLElement>(null);
  const user = useAuthStore((state) => state.user);
  const workspaces = useAuthStore((state) => state.workspaces);
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const collapsed = useUiStore((state) => state.sidebarCollapsed);
  const toggleSidebar = useUiStore((state) => state.toggleSidebar);
  const workspace = workspaces.find((item) => item.id === workspaceId);
  const closeMobileNavigation = () => {
    if (collapsed && window.matchMedia("(max-width: 760px)").matches) toggleSidebar();
  };

  useEffect(() => {
    if (!collapsed || !window.matchMedia("(max-width: 760px)").matches) return;
    const previousFocus =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;
    sidebarRef.current?.querySelector<HTMLButtonElement>(".wf-sidebar-close")?.focus();
    const closeOnEscape = (event: KeyboardEvent) => {
      if (!window.matchMedia("(max-width: 760px)").matches || event.defaultPrevented) return;
      // Workspace and account menus own their keyboard handling while open.
      if (document.activeElement?.closest('[role="menu"], [role="dialog"]')) return;
      if (event.key === "Escape") {
        event.preventDefault();
        toggleSidebar();
      } else if (event.key === "Tab") {
        const controls = Array.from(
          sidebarRef.current?.querySelectorAll<HTMLElement>(
            'a[href], button:not(:disabled), input, select, [tabindex="0"]',
          ) ?? [],
        ).filter((element) => element.offsetParent !== null);
        const first = controls[0];
        const last = controls[controls.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last?.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first?.focus();
        }
      }
    };
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      window.removeEventListener("keydown", closeOnEscape);
      if (previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
    };
  }, [collapsed, toggleSidebar]);

  return (
    <>
      {collapsed && (
        <button
          type="button"
          className="wf-sidebar-scrim"
          aria-label="Close navigation"
          onClick={toggleSidebar}
        />
      )}
      <aside ref={sidebarRef} className={`wf-sidebar${collapsed ? " is-collapsed" : ""}`}>
        <Link to="/dashboard" className="wf-brand" aria-label="mokaid home">
          <span className="wf-brand-mark">
            <LogoMark size={64} />
          </span>
          <span>mokaid</span>
        </Link>
        <button
          className="wf-sidebar-close"
          type="button"
          aria-label="Close navigation"
          onClick={toggleSidebar}
        >
          <X size={18} />
        </button>

        <div className="wf-sidebar-workspace">
          <WorkspaceProjectSwitcher />
        </div>

        <nav className="wf-navigation" aria-label="Main navigation">
          {workforceNav.map(({ to, label, icon: Icon }) => (
            <Link
              key={to}
              to={to}
              data-tour={`nav-${to.slice(1)}`}
              className={`wf-nav-link${to === "/agents" ? " is-active" : ""}`}
              aria-current={to === "/agents" ? "page" : undefined}
              title={label}
              onClick={closeMobileNavigation}
            >
              <Icon size={21} strokeWidth={1.65} aria-hidden />
              <span>{label}</span>
              {to === "/agents" && <i className="wf-active-light" aria-hidden />}
            </Link>
          ))}
        </nav>

        <Link to="/agents/new" className="wf-promo">
          <span>
            Multiply
            <br />
            your impact
            <br />
            with AI agents.
          </span>
          <span className="wf-promo-orb" aria-hidden />
          <span className="wf-promo-arrow" aria-hidden>
            <ArrowRight size={19} />
          </span>
        </Link>

        <div className="wf-profile">
          <Link to="/profile" className="wf-profile-link" title={user?.full_name || "Your profile"}>
            <Avatar name={user?.full_name} src={user?.avatar_url} size="md" color="#343054" />
            <span className="wf-profile-copy">
              <strong>{user?.full_name || "Your profile"}</strong>
              <span>{workspace?.role_name || "Member"}</span>
            </span>
          </Link>
          <DropdownMenu.Root>
            <DropdownMenu.Trigger asChild>
              <button
                type="button"
                className="wf-profile-more"
                aria-label="Workspace and account options"
              >
                <MoreHorizontal size={18} />
              </button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content
                align="end"
                side="top"
                sideOffset={10}
                className="wf-shell-menu"
              >
                {workspaceLinks.map(({ to, label, icon: Icon }) => (
                  <DropdownMenu.Item key={to} asChild>
                    <Link to={to}>
                      <Icon size={15} aria-hidden />
                      {label}
                    </Link>
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
        </div>
      </aside>
    </>
  );
}

export function WorkforceTopbar() {
  const containerRef = useRef<HTMLDivElement>(null);
  const [online, setOnline] = useState(() => typeof navigator === "undefined" || navigator.onLine);

  useEffect(() => {
    const updateConnection = () => setOnline(navigator.onLine);
    const focusSearch = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        containerRef.current?.querySelector<HTMLInputElement>("input")?.focus();
      }
    };
    window.addEventListener("online", updateConnection);
    window.addEventListener("offline", updateConnection);
    window.addEventListener("keydown", focusSearch);
    return () => {
      window.removeEventListener("online", updateConnection);
      window.removeEventListener("offline", updateConnection);
      window.removeEventListener("keydown", focusSearch);
    };
  }, []);

  return (
    <div ref={containerRef} className="wf-topbar">
      <Topbar />
      <span
        className={`wf-connection${online ? "" : " is-offline"}`}
        title="Browser network connection"
        role="status"
      >
        <i aria-hidden />
        {online ? "Online" : "Offline"}
      </span>
    </div>
  );
}
