import { Link } from "@tanstack/react-router";
import { Download, ShieldCheck } from "lucide-react";
import { PasswordSection } from "@/components/profile/password-section";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { PageHeader } from "@/components/ui/page-header";
import { useAuthStore } from "@/stores/auth-store";

export function AccountPage() {
  const user = useAuthStore((state) => state.user);
  return (
    <div className="max-w-3xl space-y-6">
      <PageHeader
        title="Your account"
        subtitle={`${user?.full_name ? `Welcome, ${user.full_name}. ` : ""}Manage your profile, security and billing online.`}
      />
      <Card>
        <CardHeader>
          <CardTitle>Mokaid Desktop</CardTitle>
        </CardHeader>
        <CardBody className="space-y-4">
          <p className="text-sm text-text-secondary">
            Your office, agents, conversations, projects and calendar live in the desktop
            application. Sign in there with the same Mokaid account.
          </p>
          <Link
            to="/download"
            className="mk-focus-ring inline-flex items-center gap-2 rounded-md bg-primary px-4 py-2 text-sm font-medium text-white"
          >
            <Download size={16} aria-hidden /> Download for macOS or Windows
          </Link>
        </CardBody>
      </Card>
      <div className="grid gap-4 sm:grid-cols-2">
        <Card>
          <CardBody className="space-y-2 pt-5">
            <h2 className="text-sm font-semibold">Account & security</h2>
            <p className="text-xs text-text-muted">
              Update your personal details, preferences and password.
            </p>
            <Link
              to="/account/profile"
              className="mk-focus-ring inline-block rounded text-sm text-primary-light"
            >
              Manage profile
            </Link>
          </CardBody>
        </Card>
        <Card>
          <CardBody className="space-y-2 pt-5">
            <h2 className="text-sm font-semibold">Workspace billing</h2>
            <p className="text-xs text-text-muted">
              Manage plans, credits, usage and invoices for your selected workspace.
            </p>
            <Link
              to="/account/billing"
              className="mk-focus-ring inline-block rounded text-sm text-primary-light"
            >
              Manage billing
            </Link>
          </CardBody>
        </Card>
      </div>
    </div>
  );
}

export function AccountSecurityPage() {
  const user = useAuthStore((state) => state.user);
  return (
    <div className="max-w-3xl space-y-5">
      <PageHeader title="Security" subtitle="Manage how you sign in to Mokaid." />
      <Card>
        <CardBody className="flex items-start gap-3 pt-5">
          <ShieldCheck size={20} className="text-primary-light" aria-hidden />
          <div>
            <p className="break-all text-sm font-semibold">{user?.email}</p>
            <p className="mt-1 text-xs text-text-muted">
              {user?.auth_provider === "google"
                ? "Google sign-in. Manage two-step verification in your Google account."
                : "Your password is managed by Mokaid."}
            </p>
          </div>
        </CardBody>
      </Card>
      <PasswordSection />
    </div>
  );
}
