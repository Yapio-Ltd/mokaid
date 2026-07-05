import { useState } from "react";
import { Outlet } from "@tanstack/react-router";
import { Sidebar } from "./sidebar";
import { Topbar } from "./topbar";
import { useWorkspaceChannel } from "@/realtime/use-workspace-channel";
import { useProjects } from "@/api/hooks";
import { OnboardingWizard } from "@/components/onboarding/onboarding-wizard";
import { CoachmarkTour } from "@/components/onboarding/coachmark-tour";
import { useAuthStore } from "@/stores/auth-store";
import { useOnboardingStore } from "@/stores/onboarding-store";

function OnboardingGate() {
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const wizardDone = useOnboardingStore((s) => s.wizardDone);
  const [dismissed, setDismissed] = useState(false);
  const { data: projects, isSuccess } = useProjects();

  const shouldShow =
    !dismissed &&
    workspaceId != null &&
    !wizardDone[workspaceId] &&
    isSuccess &&
    (projects?.data.length ?? 0) === 0;

  if (!shouldShow) return null;
  return <OnboardingWizard onFinish={() => setDismissed(true)} />;
}

export function AppShell() {
  useWorkspaceChannel();

  return (
    <div className="flex h-full overflow-hidden">
      <Sidebar />
      <div className="flex min-w-0 flex-1 flex-col">
        <Topbar />
        <main className="min-h-0 flex-1 overflow-y-auto p-5">
          <Outlet />
        </main>
      </div>
      <OnboardingGate />
      <CoachmarkTour />
    </div>
  );
}
