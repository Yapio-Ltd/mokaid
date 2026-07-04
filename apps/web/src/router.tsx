import {
  createRootRoute,
  createRoute,
  createRouter,
  redirect,
  Outlet,
} from "@tanstack/react-router";
import { AppShell } from "@/components/layout/app-shell";
import { useAuthStore } from "@/stores/auth-store";
import { LoginPage } from "@/pages/login";
import { DashboardPage } from "@/pages/dashboard";
import { AgentsPage } from "@/pages/agents";
import { TasksPage } from "@/pages/tasks";
import { ProjectsPage } from "@/pages/projects";
import { KnowledgePage } from "@/pages/knowledge";
import { DrivePage } from "@/pages/drive";
import { CalendarPage } from "@/pages/calendar";
import { AnalyticsPage } from "@/pages/analytics";
import { SettingsPage } from "@/pages/settings";
import { MembersPage } from "@/pages/members";
import { IntegrationsPage } from "@/pages/integrations";
import { BillingPage } from "@/pages/billing";

const rootRoute = createRootRoute({
  component: () => <Outlet />,
});

const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/login",
  component: LoginPage,
  beforeLoad: () => {
    if (useAuthStore.getState().token) {
      throw redirect({ to: "/" });
    }
  },
});

const appRoute = createRoute({
  getParentRoute: () => rootRoute,
  id: "app",
  component: AppShell,
  beforeLoad: () => {
    if (!useAuthStore.getState().token) {
      throw redirect({ to: "/login" });
    }
  },
});

const pages = [
  { path: "/", component: DashboardPage },
  { path: "/agents", component: AgentsPage },
  { path: "/tasks", component: TasksPage },
  { path: "/projects", component: ProjectsPage },
  { path: "/knowledge", component: KnowledgePage },
  { path: "/drive", component: DrivePage },
  { path: "/calendar", component: CalendarPage },
  { path: "/analytics", component: AnalyticsPage },
  { path: "/settings", component: SettingsPage },
  { path: "/members", component: MembersPage },
  { path: "/integrations", component: IntegrationsPage },
  { path: "/billing", component: BillingPage },
] as const;

const pageRoutes = pages.map(({ path, component }) =>
  createRoute({ getParentRoute: () => appRoute, path, component }),
);

const routeTree = rootRoute.addChildren([loginRoute, appRoute.addChildren(pageRoutes)]);

export const router = createRouter({ routeTree });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}
