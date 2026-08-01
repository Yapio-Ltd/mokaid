import { lazy, Suspense, type ComponentType } from "react";
import {
  createRootRoute,
  createRoute,
  createRouter,
  redirect,
  Outlet,
} from "@tanstack/react-router";
import { useAuthStore } from "@/stores/auth-store";
import { LandingPage } from "@/pages/landing";
import { LoginPage } from "@/pages/login";
import { SignupPage } from "@/pages/signup";

/** Wrap a lazy page so route transitions don't blank the shell without feedback. */
function lazyPage(loader: () => Promise<{ default: ComponentType }>) {
  const Comp = lazy(loader);
  return function LazyRoutePage() {
    return (
      <Suspense
        fallback={
          <div className="flex h-full min-h-[40vh] items-center justify-center text-sm text-text-muted">
            Loading…
          </div>
        }
      >
        <Comp />
      </Suspense>
    );
  };
}

const AppShell = lazyPage(() =>
  import("@/components/layout/app-shell").then((m) => ({ default: m.AppShell })),
);

const DashboardPage = lazyPage(() =>
  import("@/pages/dashboard").then((m) => ({ default: m.DashboardPage })),
);
const AgentsPage = lazyPage(() =>
  import("@/pages/agents").then((m) => ({ default: m.AgentsPage })),
);
const AgentsNewPage = lazyPage(() =>
  import("@/pages/agents-new").then((m) => ({ default: m.AgentsNewPage })),
);
const AgentTrainingPage = lazyPage(() =>
  import("@/pages/agent-training").then((m) => ({ default: m.AgentTrainingPage })),
);
const TasksPage = lazyPage(() =>
  import("@/pages/tasks").then((m) => ({ default: m.TasksPage })),
);
const ProjectsPage = lazyPage(() =>
  import("@/pages/projects").then((m) => ({ default: m.ProjectsPage })),
);
const KnowledgePage = lazyPage(() =>
  import("@/pages/knowledge").then((m) => ({ default: m.KnowledgePage })),
);
const DrivePage = lazyPage(() =>
  import("@/pages/drive").then((m) => ({ default: m.DrivePage })),
);
const CalendarPage = lazyPage(() =>
  import("@/pages/calendar").then((m) => ({ default: m.CalendarPage })),
);
const AnalyticsPage = lazyPage(() =>
  import("@/pages/analytics").then((m) => ({ default: m.AnalyticsPage })),
);
const SettingsPage = lazyPage(() =>
  import("@/pages/settings").then((m) => ({ default: m.SettingsPage })),
);
const ProfilePage = lazyPage(() =>
  import("@/pages/profile").then((m) => ({ default: m.ProfilePage })),
);
const MembersPage = lazyPage(() =>
  import("@/pages/members").then((m) => ({ default: m.MembersPage })),
);
const McpHubPage = lazyPage(() =>
  import("@/pages/mcp-hub").then((m) => ({ default: m.McpHubPage })),
);
const BillingPage = lazyPage(() =>
  import("@/pages/billing").then((m) => ({ default: m.BillingPage })),
);
const FigmaCallbackPage = lazyPage(() =>
  import("@/pages/figma-callback").then((m) => ({ default: m.FigmaCallbackPage })),
);
const GoogleCallbackPage = lazyPage(() =>
  import("@/pages/google-callback").then((m) => ({ default: m.GoogleCallbackPage })),
);
const GoogleAuthCallbackPage = lazyPage(() =>
  import("@/pages/google-auth-callback").then((m) => ({ default: m.GoogleAuthCallbackPage })),
);
const GithubCallbackPage = lazyPage(() =>
  import("@/pages/github-callback").then((m) => ({ default: m.GithubCallbackPage })),
);
const LinearCallbackPage = lazyPage(() =>
  import("@/pages/linear-callback").then((m) => ({ default: m.LinearCallbackPage })),
);
const SlackCallbackPage = lazyPage(() =>
  import("@/pages/slack-callback").then((m) => ({ default: m.SlackCallbackPage })),
);
const NotionCallbackPage = lazyPage(() =>
  import("@/pages/notion-callback").then((m) => ({ default: m.NotionCallbackPage })),
);
const PrivacyPage = lazyPage(() =>
  import("@/pages/privacy").then((m) => ({ default: m.PrivacyPage })),
);
const TermsPage = lazyPage(() =>
  import("@/pages/terms").then((m) => ({ default: m.TermsPage })),
);
const CookiesPage = lazyPage(() =>
  import("@/pages/cookies").then((m) => ({ default: m.CookiesPage })),
);
const LegalPage = lazyPage(() =>
  import("@/pages/legal").then((m) => ({ default: m.LegalPage })),
);

const rootRoute = createRootRoute({
  component: () => <Outlet />,
});

const landingRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: LandingPage,
});

const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/login",
  component: LoginPage,
  beforeLoad: () => {
    if (useAuthStore.getState().token) {
      throw redirect({ to: "/dashboard" });
    }
  },
});

const signupRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/signup",
  component: SignupPage,
  beforeLoad: () => {
    if (useAuthStore.getState().token) {
      throw redirect({ to: "/dashboard" });
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
  { path: "/dashboard", component: DashboardPage },
  { path: "/agents", component: AgentsPage },
  { path: "/tasks", component: TasksPage },
  { path: "/projects", component: ProjectsPage },
  { path: "/knowledge", component: KnowledgePage },
  { path: "/drive", component: DrivePage },
  { path: "/calendar", component: CalendarPage },
  { path: "/analytics", component: AnalyticsPage },
  { path: "/settings", component: SettingsPage },
  { path: "/profile", component: ProfilePage },
  { path: "/members", component: MembersPage },
  { path: "/integrations", component: McpHubPage },
  { path: "/billing", component: BillingPage },
] as const;

const pageRoutes = pages.map(({ path, component }) =>
  createRoute({ getParentRoute: () => appRoute, path, component }),
);

const agentsNewRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/agents/new",
  component: AgentsNewPage,
});

const agentTrainingRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/agents/$agentId/training",
  component: AgentTrainingPage,
});

const figmaCallbackRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/oauth/figma/callback",
  component: FigmaCallbackPage,
});

const googleCallbackRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/oauth/google/callback",
  component: GoogleCallbackPage,
});

const googleAuthCallbackRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/auth/google/callback",
  component: GoogleAuthCallbackPage,
});

const githubCallbackRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/oauth/github/callback",
  component: GithubCallbackPage,
});

const linearCallbackRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/oauth/linear/callback",
  component: LinearCallbackPage,
});

const slackCallbackRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/oauth/slack/callback",
  component: SlackCallbackPage,
});

const notionCallbackRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/auth/notion/callback",
  component: NotionCallbackPage,
});

const privacyRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/privacy",
  component: PrivacyPage,
});

const termsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/terms",
  component: TermsPage,
});

const cookiesRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/cookies",
  component: CookiesPage,
});

const legalRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/legal",
  component: LegalPage,
});

const routeTree = rootRoute.addChildren([
  landingRoute,
  loginRoute,
  signupRoute,
  figmaCallbackRoute,
  googleCallbackRoute,
  googleAuthCallbackRoute,
  githubCallbackRoute,
  linearCallbackRoute,
  slackCallbackRoute,
  notionCallbackRoute,
  privacyRoute,
  termsRoute,
  cookiesRoute,
  legalRoute,
  appRoute.addChildren([...pageRoutes, agentsNewRoute, agentTrainingRoute]),
]);

export const router = createRouter({ routeTree });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}
