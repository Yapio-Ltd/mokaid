import { lazy, Suspense, type ComponentType } from "react";
import {
  createRootRoute,
  createRoute,
  createRouter,
  redirect,
  Outlet,
  useRouterState,
} from "@tanstack/react-router";
import { useAuthStore } from "@/stores/auth-store";
import { shouldSkipLanding } from "@/lib/session-entry";
import { CookieConsent } from "@/components/legal/cookie-consent";
import { LandingPage } from "@/pages/landing";
import { LoginPage } from "@/pages/login";
import { SignupPage } from "@/pages/signup";
import { ApiError, apiFetch } from "@/api/client";
import { waitForAuthHydration } from "@/lib/oauth-callback";
import {
  ACCOUNT_LINKS,
  DESKTOP_ONLY_WEB,
  accountEntryPath,
  authReturnFromSearch,
  legacyAccountDestination,
  localNavigation,
  safeAuthReturn,
} from "@/lib/desktop-rollout";
import { useSeo } from "@/lib/use-seo";

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

// These literal branches are removed by Rollup in the account-only build.
// Keeping the import itself inside the branch also excludes Babylon's graph.
const UnavailableExperience = () => null;
const AppShell = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/components/layout/app-shell").then((m) => ({ default: m.AppShell })));

const DashboardPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/dashboard").then((m) => ({ default: m.DashboardPage })));
const AgentsPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/agents").then((m) => ({ default: m.AgentsPage })));
const AgentsNewPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/agents-new").then((m) => ({ default: m.AgentsNewPage })));
const AgentTrainingPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() =>
      import("@/pages/agent-training").then((m) => ({ default: m.AgentTrainingPage })),
    );
const AgentDetailPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/agent-detail").then((m) => ({ default: m.AgentDetailPage })));
const TasksPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/tasks").then((m) => ({ default: m.TasksPage })));
const ProjectsPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/projects").then((m) => ({ default: m.ProjectsPage })));
const KnowledgePage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/knowledge").then((m) => ({ default: m.KnowledgePage })));
const DrivePage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/drive").then((m) => ({ default: m.DrivePage })));
const CalendarPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/calendar").then((m) => ({ default: m.CalendarPage })));
const MailPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/mail").then((m) => ({ default: m.MailPage })));
const AnalyticsPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/analytics").then((m) => ({ default: m.AnalyticsPage })));
const SettingsPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/settings").then((m) => ({ default: m.SettingsPage })));
const ProfilePage = lazyPage(() =>
  import("@/pages/profile").then((m) => ({ default: m.ProfilePage })),
);
const MembersPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/members").then((m) => ({ default: m.MembersPage })));
const McpHubPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/mcp-hub").then((m) => ({ default: m.McpHubPage })));
const BillingPage = DESKTOP_ONLY_WEB
  ? UnavailableExperience
  : lazyPage(() => import("@/pages/billing").then((m) => ({ default: m.BillingPage })));
const FigmaCallbackPage = lazyPage(() =>
  import("@/pages/figma-callback").then((m) => ({ default: m.FigmaCallbackPage })),
);
const GoogleCallbackPage = lazyPage(() =>
  import("@/pages/google-callback").then((m) => ({ default: m.GoogleCallbackPage })),
);
const GoogleAuthCallbackPage = lazyPage(() =>
  import("@/pages/google-auth-callback").then((m) => ({ default: m.GoogleAuthCallbackPage })),
);
const DesktopAuthorizePage = lazyPage(() =>
  import("@/pages/desktop-authorize").then((m) => ({ default: m.DesktopAuthorizePage })),
);
const DownloadPage = lazyPage(() =>
  import("@/pages/download").then((m) => ({ default: m.DownloadPage })),
);
const MarketplaceReturnPage = lazyPage(() =>
  import("@/pages/marketplace-return").then((m) => ({ default: m.MarketplaceReturnPage })),
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
const TermsPage = lazyPage(() => import("@/pages/terms").then((m) => ({ default: m.TermsPage })));
const CookiesPage = lazyPage(() =>
  import("@/pages/cookies").then((m) => ({ default: m.CookiesPage })),
);
const LegalPage = lazyPage(() => import("@/pages/legal").then((m) => ({ default: m.LegalPage })));
const RefundPage = lazyPage(() =>
  import("@/pages/refund").then((m) => ({ default: m.RefundPage })),
);
const AccountShell = lazyPage(() =>
  import("@/components/account/account-shell").then((m) => ({ default: m.AccountShell })),
);
const AccountPage = lazyPage(() =>
  import("@/pages/account").then((m) => ({ default: m.AccountPage })),
);
const AccountSecurityPage = lazyPage(() =>
  import("@/pages/account").then((m) => ({ default: m.AccountSecurityPage })),
);
const AccountBillingPage = lazyPage(() =>
  import("@/pages/account-billing").then((m) => ({ default: m.AccountBillingPage })),
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

function PrivateRouteMetadata({ path }: { path: string }) {
  useSeo({
    title: "Mokaid account",
    description: "Manage your Mokaid account securely.",
    path,
    noindex: true,
  });
  return null;
}

function RootLayout() {
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const isPrivate =
    /^\/(account|login|signup|desktop|oauth|auth|dashboard|agents|tasks|projects|knowledge|drive|mail|calendar|analytics|settings|profile|members|integrations|billing)(\/|$)/.test(
      pathname,
    );
  return (
    <>
      {isPrivate && <PrivateRouteMetadata path={pathname} />}
      <Outlet />
      <CookieConsent />
    </>
  );
}

const rootRoute = createRootRoute({
  component: RootLayout,
  errorComponent: () => (
    <main className="flex min-h-screen flex-col items-center justify-center gap-4 bg-bg-deep p-6 text-text">
      <PrivateRouteMetadata path={window.location.pathname} />
      <h1 className="text-xl font-semibold">This page could not be loaded</h1>
      <p className="text-sm text-text-muted">Check your connection and try again.</p>
      <button
        className="mk-focus-ring rounded-md bg-primary px-4 py-2 text-white"
        onClick={() => window.location.reload()}
      >
        Try again
      </button>
      <a href="/account" className="text-primary-light">
        Back to account
      </a>
    </main>
  ),
});

const landingRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: LandingPage,
  beforeLoad: ({ location }) => {
    if (
      !DESKTOP_ONLY_WEB &&
      shouldSkipLanding(location.searchStr, Boolean(useAuthStore.getState().token))
    ) {
      throw redirect({ to: accountEntryPath() });
    }
  },
});

const loginRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/login",
  component: LoginPage,
  validateSearch: (search: Record<string, unknown>): { returnTo?: string } => ({
    returnTo: typeof search.returnTo === "string" ? search.returnTo : undefined,
  }),
  beforeLoad: async ({ location }) => {
    await waitForAuthHydration();
    if (useAuthStore.getState().token) {
      throw redirect(localNavigation(authReturnFromSearch(location.searchStr)));
    }
  },
});

const desktopAuthorizeRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/desktop/authorize",
  component: DesktopAuthorizePage,
});

const signupRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/signup",
  component: SignupPage,
  validateSearch: (search: Record<string, unknown>): { returnTo?: string } => ({
    returnTo: typeof search.returnTo === "string" ? search.returnTo : undefined,
  }),
  beforeLoad: async ({ location }) => {
    await waitForAuthHydration();
    if (useAuthStore.getState().token) {
      throw redirect(localNavigation(authReturnFromSearch(location.searchStr)));
    }
  },
});

const appRoute = createRoute({
  getParentRoute: () => rootRoute,
  id: "app",
  component: AppShell,
  beforeLoad: async ({ location }) => {
    if (DESKTOP_ONLY_WEB)
      throw redirect({
        ...localNavigation(legacyAccountDestination(location.pathname, location.searchStr)),
        replace: true,
      });
    await waitForAuthHydration();
    if (!useAuthStore.getState().token) {
      throw redirect({ to: "/login", search: { returnTo: safeAuthReturn(location.href) } });
    }
    // The server can tighten policy before a cached older web build is replaced.
    // Check before mounting AppShell, which owns Channels and the 3D renderer.
    let policy: { client_policy?: { desktop_only_business?: boolean } };
    try {
      policy = await apiFetch("/api/me", { skipWorkspace: true });
    } catch (error) {
      if (error instanceof ApiError && error.status === 401) {
        throw redirect({ to: "/login", search: { returnTo: safeAuthReturn(location.href) } });
      }
      throw error;
    }
    if (policy.client_policy?.desktop_only_business) {
      throw redirect({
        ...localNavigation(legacyAccountDestination(location.pathname, location.searchStr)),
        replace: true,
      });
    }
  },
});

const accountRoute = createRoute({
  getParentRoute: () => rootRoute,
  id: "account-shell",
  component: AccountShell,
  beforeLoad: async ({ location }) => {
    await waitForAuthHydration();
    if (!useAuthStore.getState().token)
      throw redirect({ to: "/login", search: { returnTo: safeAuthReturn(location.href) } });
  },
});

const accountRoutes = ACCOUNT_LINKS.map(({ path }) =>
  createRoute({
    getParentRoute: () => accountRoute,
    path,
    component:
      path === "/account"
        ? AccountPage
        : path === "/account/profile"
          ? ProfilePage
          : path === "/account/security"
            ? AccountSecurityPage
            : AccountBillingPage,
  }),
);

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

const downloadRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/download",
  component: DownloadPage,
});

const marketplaceReturnRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/marketplace/return",
  component: MarketplaceReturnPage,
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
  desktopAuthorizeRoute,
  downloadRoute,
  marketplaceReturnRoute,
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
  accountRoute.addChildren(accountRoutes),
  appRoute.addChildren([...pageRoutes, agentsNewRoute, agentTrainingRoute, agentDetailRoute]),
]);

export const router = createRouter({ routeTree });

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}
