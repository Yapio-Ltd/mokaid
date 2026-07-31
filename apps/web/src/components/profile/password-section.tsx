import { useEffect, useState, type FormEvent } from "react";
import { ApiError } from "@/api/client";
import { useChangePassword, useMe } from "@/api/hooks";
import { Button } from "@/components/ui/button";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { Field } from "@/components/ui/field";
import { SkeletonRows } from "@/components/ui/skeleton";
import { useAuthStore } from "@/stores/auth-store";
import { toast } from "@/stores/toast-store";

export function PasswordSection() {
  const { data: meData, isLoading: meLoading } = useMe();
  const setSession = useAuthStore((s) => s.setSession);
  const token = useAuthStore((s) => s.token);
  const storedUser = useAuthStore((s) => s.user);
  const changePassword = useChangePassword();

  const [currentPassword, setCurrentPassword] = useState("");
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [formError, setFormError] = useState<string | null>(null);

  const hasPassword = meData?.user.has_password ?? storedUser?.has_password;
  const provider = meData?.user.auth_provider ?? storedUser?.auth_provider;

  useEffect(() => {
    if (meData?.user && token) {
      setSession(token, {
        id: meData.user.id,
        email: meData.user.email,
        full_name: meData.user.full_name,
        avatar_url: meData.user.avatar_url,
        has_avatar: meData.user.has_avatar,
        has_password: meData.user.has_password,
        locale: meData.user.locale,
        timezone: meData.user.timezone,
        mfa_enabled: meData.user.mfa_enabled,
        last_login_at: meData.user.last_login_at,
        auth_provider: meData.user.auth_provider,
      });
    }
  }, [meData?.user, setSession, token]);

  if (meLoading && hasPassword == null) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Password</CardTitle>
        </CardHeader>
        <CardBody>
          <SkeletonRows rows={3} />
        </CardBody>
      </Card>
    );
  }

  if (!hasPassword) {
    return (
      <Card>
        <CardHeader>
          <CardTitle>Password</CardTitle>
        </CardHeader>
        <CardBody>
          <p className="text-xs text-text-muted">
            {provider === "google"
              ? "You sign in with Google. Password changes are managed in your Google account, not in Mokaid."
              : "You sign in with an identity provider. Password changes are managed there, not in Mokaid."}
          </p>
        </CardBody>
      </Card>
    );
  }

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setFormError(null);

    if (password.length < 10) {
      setFormError("New password must be at least 10 characters.");
      return;
    }
    if (password !== confirmation) {
      setFormError("New password and confirmation do not match.");
      return;
    }

    try {
      await changePassword.mutateAsync({
        current_password: currentPassword,
        password,
        password_confirmation: confirmation,
      });
      setCurrentPassword("");
      setPassword("");
      setConfirmation("");
      toast({
        tone: "success",
        title: "Password updated",
        description: "Use your new password next time you sign in.",
      });
    } catch (err) {
      if (err instanceof ApiError) {
        const details = err.details as Record<string, string[] | undefined> | undefined;
        const firstDetail =
          details?.current_password?.[0] ||
          details?.password_confirmation?.[0] ||
          details?.password?.[0];
        setFormError(firstDetail || err.message);
      } else {
        setFormError(err instanceof Error ? err.message : "Could not update password");
      }
    }
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Password</CardTitle>
      </CardHeader>
      <CardBody>
        <form className="space-y-4" onSubmit={submit}>
          <Field label="Current password" required>
            <input
              type="password"
              autoComplete="current-password"
              className="mk-input"
              value={currentPassword}
              onChange={(e) => setCurrentPassword(e.target.value)}
              required
            />
          </Field>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="New password" required hint="At least 10 characters">
              <input
                type="password"
                autoComplete="new-password"
                className="mk-input"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
                minLength={10}
              />
            </Field>
            <Field label="Confirm new password" required>
              <input
                type="password"
                autoComplete="new-password"
                className="mk-input"
                value={confirmation}
                onChange={(e) => setConfirmation(e.target.value)}
                required
                minLength={10}
              />
            </Field>
          </div>
          {formError && (
            <p className="rounded-lg border border-danger/30 bg-danger/10 px-3 py-2 text-xs text-danger">
              {formError}
            </p>
          )}
          <div className="flex justify-end">
            <Button type="submit" size="sm" loading={changePassword.isPending}>
              Update password
            </Button>
          </div>
        </form>
      </CardBody>
    </Card>
  );
}
