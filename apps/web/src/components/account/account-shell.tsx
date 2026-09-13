import { useEffect } from "react";
import { Link, Outlet, useNavigate, useRouterState } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import { Download, LogOut } from "lucide-react";
import { useMe } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Toaster } from "@/components/ui/toaster";
import { ACCOUNT_LINKS } from "@/lib/desktop-rollout";
import { useAuthStore } from "@/stores/auth-store";

/** Deliberately no AppShell, Channels, chat, onboarding or renderer dependency. */
export function AccountShell() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const token = useAuthStore((state) => state.token);
  const workspaceId = useAuthStore((state) => state.workspaceId);
  const selectWorkspace = useAuthStore((state) => state.selectWorkspace);
  const patchUser = useAuthStore((state) => state.patchUser);
  const setWorkspaces = useAuthStore((state) => state.setWorkspaces);
  const { data, error, isPending, refetch } = useMe();
  const pathname = useRouterState({ select: (state) => state.location.pathname });

  useEffect(() => {
    if (!token) {
      void queryClient.cancelQueries();
      queryClient.clear();
      void navigate({ to: "/login", search: { returnTo: pathname }, replace: true });
    }
  }, [token, queryClient, navigate, pathname]);

  useEffect(() => {
    if (!data || !token) return;
    patchUser(data.user);
    setWorkspaces(data.workspaces);
  }, [data, token, patchUser, setWorkspaces]);

  const switchWorkspace = async (id: string) => {
    if (!data?.workspaces.some((workspace) => workspace.id === id) || id === workspaceId) return;
    await queryClient.cancelQueries();
    queryClient.removeQueries({ predicate: (query) => query.queryKey[0] !== "me" });
    selectWorkspace(id);
  };

  const signOut = async () => {
    await queryClient.cancelQueries();
    queryClient.clear();
    useAuthStore.getState().logout();
  };

  return (
    <div className="flex h-full flex-col overflow-y-auto bg-bg-deep text-text">
      <a href="#account-content" className="sr-only focus:not-sr-only focus:p-3">
        Skip to account content
      </a>
      <header className="flex flex-wrap items-center justify-between gap-4 border-b border-border px-5 py-4">
        <Link to="/" className="mk-focus-ring flex items-center gap-2 rounded-md">
          <img src="/branding/logo-without-bg.png" alt="" className="h-8 w-8 object-contain" />
          <span className="font-bold">
            mokaid <span className="font-normal text-text-muted">/ Account</span>
          </span>
        </Link>
        <div className="flex items-center gap-3">
          <Link
            to="/download"
            className="mk-focus-ring inline-flex items-center gap-2 rounded-md px-3 py-2 text-sm text-primary-light"
          >
            <Download size={16} aria-hidden /> Download desktop
          </Link>
          <Button variant="ghost" size="sm" onClick={() => void signOut()}>
            <LogOut size={15} aria-hidden /> Sign out
          </Button>
        </div>
      </header>
      <div className="mx-auto grid w-full max-w-7xl flex-1 gap-8 px-5 py-7 md:grid-cols-[220px_minmax(0,1fr)]">
        <aside className="space-y-5">
          <div>
            <label
              htmlFor="account-workspace"
              className="mb-2 block text-xs font-medium text-text-muted"
            >
              Billing workspace
            </label>
            <select
              id="account-workspace"
              className="mk-input w-full"
              value={workspaceId ?? ""}
              disabled={!data?.workspaces.length}
              onChange={(event) => void switchWorkspace(event.target.value)}
            >
              {!data?.workspaces.length && <option value="">No workspace</option>}
              {data?.workspaces.map((workspace) => (
                <option key={workspace.id} value={workspace.id}>
                  {workspace.name}
                </option>
              ))}
            </select>
          </div>
          <nav aria-label="Account" className="flex flex-wrap gap-1 md:flex-col">
            {ACCOUNT_LINKS.map((item) => (
              <Link
                key={item.path}
                to={item.path}
                preload={false}
                aria-current={pathname === item.path ? "page" : undefined}
                className={`mk-focus-ring rounded-md px-3 py-2 text-sm ${pathname === item.path ? "bg-primary-muted text-primary-light" : "text-text-secondary hover:bg-surface-raised"}`}
              >
                {item.label}
              </Link>
            ))}
          </nav>
          <p className="text-xs leading-relaxed text-text-muted">
            Manage your account and billing here. Your office, agents and work are in Mokaid
            Desktop.
          </p>
        </aside>
        <main id="account-content" tabIndex={-1} className="min-w-0">
          {isPending ? (
            <p role="status" className="text-sm text-text-muted">
              Loading your account…
            </p>
          ) : error ? (
            <div role="alert" className="space-y-3">
              <p>We could not load your account. Check your connection and try again.</p>
              <Button onClick={() => void refetch()}>Try again</Button>
            </div>
          ) : token ? (
            <Outlet />
          ) : null}
        </main>
      </div>
      <Toaster />
    </div>
  );
}
