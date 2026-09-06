import { useEffect, useState } from "react";
import { Outlet, useRouterState } from "@tanstack/react-router";
import { Sidebar } from "./sidebar";
import { Topbar } from "./topbar";
import { useWorkspaceChannel } from "@/realtime/use-workspace-channel";
import { useOnboardingSettings } from "@/api/hooks";
import { apiFetch } from "@/api/client";
import { OnboardingWizard } from "@/components/onboarding/onboarding-wizard";
import { CoachmarkTour } from "@/components/onboarding/coachmark-tour";
import { ReviewBanner } from "@/components/approvals/review-banner";
import { ReviewGateModal } from "@/components/approvals/review-gate-modal";
import { useReviewQueueHydration } from "@/components/approvals/use-review-queue-hydration";
import { TaskDetailPanel } from "@/components/tasks/task-detail-panel";
import { DeliverableViewer } from "@/components/deliverables/deliverable-viewer";
import { FloatingChatDock } from "@/components/chat/floating-chat-dock";
import { Toaster } from "@/components/ui/toaster";
import { useUiStore } from "@/stores/ui-store";
import { useAuthStore, type WorkspaceSummary } from "@/stores/auth-store";
import { OfficePark } from "@/three/office-park";

function OnboardingGate() {
  const [dismissed, setDismissed] = useState(false);
  const { onboarding, loaded } = useOnboardingSettings();

  // Show the wizard exactly once per workspace: the flag lives in the DB
  // (workspace.settings.onboarding.wizard_done), not in this browser.
  const shouldShow = !dismissed && loaded && onboarding.wizard_done !== true;

  if (!shouldShow) return null;
  return <OnboardingWizard onFinish={() => setDismissed(true)} />;
}

/** Reconcile workspaces after login / repair so a missing membership is healed. */
function useSessionWorkspaceSync() {
  const token = useAuthStore((s) => s.token);
  const setWorkspaces = useAuthStore((s) => s.setWorkspaces);
  const patchUser = useAuthStore((s) => s.patchUser);

  useEffect(() => {
    if (!token) return;
    let cancelled = false;

    (async () => {
      try {
        const me = await apiFetch<{
          user: {
            id: string;
            email: string;
            full_name: string;
            avatar_url: string | null;
            has_password?: boolean;
          };
          workspaces: WorkspaceSummary[];
        }>("/api/me", { skipWorkspace: true });
        if (cancelled) return;
        patchUser(me.user);
        setWorkspaces(me.workspaces ?? []);
      } catch {
        // 401 handled by apiFetch (logout). Other errors leave local state as-is.
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [token, setWorkspaces, patchUser]);
}

export function AppShell() {
  useSessionWorkspaceSync();
  useWorkspaceChannel();
  useReviewQueueHydration();

  // Task details live at the shell level: a task can be opened from any page
  // (dashboard rows, agent panel, toasts, kanban) via useUiStore.selectTask.
  const selectedTaskId = useUiStore((s) => s.selectedTaskId);
  const selectTask = useUiStore((s) => s.selectTask);
  const selectAgent = useUiStore((s) => s.selectAgent);

  // Re-trigger the page entrance animation on top-level route changes only
  // (switching tabs inside a page must not replay the transition).
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const routeKey = pathname.split("/")[1] ?? "";

  // Side panels are shell-global: dismiss them on route change, unless a
  // toast/notification queued a task to open after landing on /tasks.
  useEffect(() => {
    if (!useUiStore.getState().consumePendingTask()) {
      selectTask(null);
    }
    selectAgent(null);
  }, [pathname, selectTask, selectAgent]);

  return (
    <div className="flex h-full overflow-hidden">
      <Sidebar />
      <div className="relative flex min-w-0 flex-1 flex-col">
        <div className="mk-main-aura" aria-hidden />
        <Topbar />
        <ReviewBanner />
        <main className="relative min-h-0 flex-1 overflow-y-auto p-5">
          <OfficePark />
          <div key={routeKey} className="mk-page h-full">
            <Outlet />
          </div>
        </main>
      </div>
      <TaskDetailPanel taskId={selectedTaskId} onClose={() => selectTask(null)} overlay />
      <DeliverableViewer />
      <FloatingChatDock />
      <OnboardingGate />
      <CoachmarkTour />
      <ReviewGateModal />
      <Toaster />
    </div>
  );
}
