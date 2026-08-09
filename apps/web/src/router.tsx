import { lazy, Suspense, type ComponentType } from "react";
import {
  createRootRoute,
  createRoute,
  createRouter,
  redirect,
  Outlet,
} from "@tanstack/react-router";
import { useAuthStore } from "@/stores/auth-store";
import { CookieConsent } from "@/components/legal/cookie-consent";
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
const AgentDetailPage = lazyPage(() =>
  import("@/pages/agent-detail").then((m) => ({ default: m.AgentDetailPage })),
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
const MailPage = lazyPage(() =>
  import("@/pages/mail").then((m) => ({ default: m.MailPage })),
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
const MicrosoftCallbackPage = lazyPage(() =>
  import("@/pages/microsoft-callback").then((m) => ({ default: m.MicrosoftCallbackPage })),
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
const RefundPage = lazyPage(() =>
  import("@/pages/refund").then((m) => ({ default: m.RefundPage })),
);

// Public SEO/content pages (prerendered post-build for search engines).
const AiEmployeesIndexPage = lazyPage(() =>
  import("@/pages/seo/ai-employees-index").then((m) => ({ default: m.AiEmployeesIndexPage })),
);
const AiEmployeeRolePage = lazyPage(() =>
  import("@/pages/seo/ai-employee-role").then((m) => ({ default: m.AiEmployeeRolePage })),
);
const UseCasesIndexPage = lazyPage(() =>
  import("@/pages/seo/use-cases-index").then((m) => ({ default: m.UseCasesIndexPage })),
);
const UseCaseDetailPage = lazyPage(() =>
  import("@/pages/seo/use-case-detail").then((m) => ({ default: m.UseCaseDetailPage })),
);
const CompareIndexPage = lazyPage(() =>
  import("@/pages/seo/compare-index").then((m) => ({ default: m.CompareIndexPage })),
);
const CompareDetailPage = lazyPage(() =>
  import("@/pages/seo/compare-detail").then((m) => ({ default: m.CompareDetailPage })),
);
const BlogIndexPage = lazyPage(() =>
  import("@/pages/seo/blog-index").then((m) => ({ default: m.BlogIndexPage })),
);
const BlogPostPage = lazyPage(() =>
  import("@/pages/seo/blog-post").then((m) => ({ default: m.BlogPostPage })),
);
const GlossaryPage = lazyPage(() =>
  import("@/pages/seo/glossary").then((m) => ({ default: m.GlossaryPage })),
);
const PricingPage = lazyPage(() =>
  import("@/pages/seo/pricing").then((m) => ({ default: m.PricingPage })),
);

function RootLayout() {
  return (
    <>
      <Outlet />
      <CookieConsent />
    </>
  );
}

const rootRoute = createRootRoute({
  component: RootLayout,
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
  { path: "/mail", component: MailPage },
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

// Deep-linkable full-page agent profile (static /agents/new ranks above it).
const agentDetailRoute = createRoute({
  getParentRoute: () => appRoute,
  path: "/agents/$agentId",
  component: AgentDetailPage,
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

const microsoftCallbackRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/oauth/microsoft/callback",
  component: MicrosoftCallbackPage,
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

const refundRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/refund",
  component: RefundPage,
});

const seoPages = [
  { path: "/ai-employees", component: AiEmployeesIndexPage },
  { path: "/ai-employees/$slug", component: AiEmployeeRolePage },
  { path: "/use-cases", component: UseCasesIndexPage },
  { path: "/use-cases/$slug", component: UseCaseDetailPage },
  { path: "/compare", component: CompareIndexPage },
  { path: "/compare/$slug", component: CompareDetailPage },
  { path: "/blog", component: BlogIndexPage },
  { path: "/blog/$slug", component: BlogPostPage },
  { path: "/glossary", component: GlossaryPage },
  { path: "/pricing", component: PricingPage },
] as const;

const seoRoutes = seoPages.map(({ path, component }) =>
  createRoute({ getParentRoute: () => rootRoute, path, component }),
);

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
  microsoftCallbackRoute,
  privacyRoute,
  termsRoute,
  cookiesRoute,
  legalRoute,
  refundRoute,
  ...seoRoutes,
  appRoute.addChildren([...pageRoutes, agentsNewRoute, agentTrainingRoute, agentDetailRoute]),
]);

export const router = createRouter({ routeTree });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}
