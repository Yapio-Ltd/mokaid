import { useEffect, useRef, useState, type ChangeEvent } from "react";
import { Check, KeyRound, Shield, ShieldCheck } from "lucide-react";
import { ApiError } from "@/api/client";
import {
  useMe,
  useRemoveAvatar,
  useUpdateMe,
  useUploadAvatar,
} from "@/api/hooks";
import { PasswordSection } from "@/components/profile/password-section";
import { Avatar } from "@/components/ui/avatar";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardBody, CardHeader, CardTitle } from "@/components/ui/card";
import { Field } from "@/components/ui/field";
import { PageHeader } from "@/components/ui/page-header";
import { SkeletonRows } from "@/components/ui/skeleton";
import { cn } from "@/lib/cn";
import { formatDateTime } from "@/lib/format";
import { useAuthStore } from "@/stores/auth-store";
import { toast } from "@/stores/toast-store";

const TIMEZONES = [
  "UTC",
  "Europe/Paris",
  "Europe/London",
  "America/New_York",
  "America/Los_Angeles",
  "Asia/Jerusalem",
  "Asia/Tokyo",
  "Asia/Singapore",
  "Australia/Sydney",
];

const LOCALES = [
  { value: "en", label: "English" },
  { value: "fr", label: "Français" },
  { value: "he", label: "עברית" },
];

function providerLabel(provider: string | undefined) {
  switch (provider) {
    case "google":
      return "Google";
    case "sso":
      return "SSO";
    default:
      return "Email & password";
  }
}

export function ProfilePage() {
  const { data, isLoading } = useMe();
  const updateMe = useUpdateMe();
  const uploadAvatar = useUploadAvatar();
  const removeAvatar = useRemoveAvatar();
  const workspaceId = useAuthStore((s) => s.workspaceId);
  const workspaces = useAuthStore((s) => s.workspaces);
  const fileRef = useRef<HTMLInputElement>(null);

  const user = data?.user;
  const meWorkspaces = data?.workspaces ?? workspaces;
  const currentWs = meWorkspaces.find((w) => w.id === workspaceId);
  const roleName = currentWs?.role_name ?? "Member";

  const [fullName, setFullName] = useState("");
  const [locale, setLocale] = useState("en");
  const [timezone, setTimezone] = useState("UTC");
  const [previewUrl, setPreviewUrl] = useState<string | null>(null);

  useEffect(() => {
    if (!user) return;
    setFullName(user.full_name);
    setLocale(user.locale || "en");
    setTimezone(user.timezone || "UTC");
  }, [user]);

  useEffect(() => {
    return () => {
      if (previewUrl) URL.revokeObjectURL(previewUrl);
    };
  }, [previewUrl]);

  if (isLoading || !user) {
    return (
      <div className="max-w-3xl space-y-5">
        <PageHeader title="Profile" />
        <SkeletonRows rows={6} />
      </div>
    );
  }

  const displayAvatar = previewUrl || user.avatar_url;
  const prefsDirty =
    locale !== (user.locale || "en") || timezone !== (user.timezone || "UTC");

  const saveProfile = async (fields?: "name" | "prefs" | "all") => {
    const name = fullName.trim();
    if (!name) {
      toast({ tone: "error", title: "Name required", description: "Please enter your full name." });
      return;
    }
    const body =
      fields === "prefs"
        ? { full_name: user.full_name, locale, timezone }
        : fields === "name"
          ? { full_name: name, locale: user.locale || "en", timezone: user.timezone || "UTC" }
          : { full_name: name, locale, timezone };
    try {
      await updateMe.mutateAsync(body);
      toast({ tone: "success", title: "Profile saved" });
    } catch (err) {
      toast({
        tone: "error",
        title: "Could not save profile",
        description: err instanceof ApiError ? err.message : "Something went wrong",
      });
    }
  };

  const onPickFile = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;

    if (!file.type.startsWith("image/")) {
      toast({ tone: "error", title: "Invalid file", description: "Choose a PNG, JPG, WebP or GIF." });
      return;
    }
    if (file.size > 5 * 1024 * 1024) {
      toast({ tone: "error", title: "File too large", description: "Max avatar size is 5 MB." });
      return;
    }

    const local = URL.createObjectURL(file);
    setPreviewUrl((prev) => {
      if (prev) URL.revokeObjectURL(prev);
      return local;
    });

    try {
      await uploadAvatar.mutateAsync(file);
      toast({ tone: "success", title: "Photo updated" });
      setPreviewUrl((prev) => {
        if (prev) URL.revokeObjectURL(prev);
        return null;
      });
    } catch (err) {
      setPreviewUrl((prev) => {
        if (prev) URL.revokeObjectURL(prev);
        return null;
      });
      toast({
        tone: "error",
        title: "Upload failed",
        description: err instanceof ApiError ? err.message : "Could not upload avatar",
      });
    }
  };

  const onRemoveAvatar = async () => {
    try {
      await removeAvatar.mutateAsync();
      setPreviewUrl((prev) => {
        if (prev) URL.revokeObjectURL(prev);
        return null;
      });
      toast({ tone: "success", title: "Photo removed" });
    } catch (err) {
      toast({
        tone: "error",
        title: "Could not remove photo",
        description: err instanceof ApiError ? err.message : "Something went wrong",
      });
    }
  };

  return (
    <div className="max-w-3xl space-y-5">
      <PageHeader title="Profile" subtitle="Your personal account, preferences and security" />

      {/* Identity */}
      <Card className="mk-fade-up">
        <CardHeader>
          <CardTitle>Identity</CardTitle>
        </CardHeader>
        <CardBody className="space-y-5">
          <div className="flex flex-wrap items-center gap-4">
            <Avatar name={user.full_name} src={displayAvatar} size="xl" color="#5936d1" />
            <div className="min-w-0 flex-1 space-y-2">
              <div className="flex flex-wrap items-center gap-2">
                <p className="truncate text-sm font-semibold text-text">{user.full_name}</p>
                <Badge tone="muted">{roleName}</Badge>
                <Badge tone={user.auth_provider === "google" ? "info" : "muted"}>
                  {providerLabel(user.auth_provider)}
                </Badge>
              </div>
              <p className="truncate text-xs text-text-muted">{user.email}</p>
              <div className="flex flex-wrap gap-2">
                <input
                  ref={fileRef}
                  type="file"
                  accept="image/png,image/jpeg,image/webp,image/gif"
                  className="hidden"
                  onChange={onPickFile}
                />
                <Button
                  type="button"
                  size="sm"
                  variant="secondary"
                  loading={uploadAvatar.isPending}
                  onClick={() => fileRef.current?.click()}
                >
                  Change photo
                </Button>
                {(user.has_avatar || user.avatar_url || previewUrl) && (
                  <Button
                    type="button"
                    size="sm"
                    variant="ghost"
                    loading={removeAvatar.isPending}
                    onClick={onRemoveAvatar}
                  >
                    Remove
                  </Button>
                )}
              </div>
            </div>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Full name" required>
              <input
                className="mk-input"
                value={fullName}
                onChange={(e) => setFullName(e.target.value)}
                maxLength={120}
              />
            </Field>
            <Field label="Email" hint="Contact support to change your email">
              <input className="mk-input" value={user.email} disabled readOnly />
            </Field>
          </div>

          <div className="flex justify-end">
            <Button
              type="button"
              size="sm"
              disabled={fullName.trim() === user.full_name}
              loading={updateMe.isPending}
              onClick={() => saveProfile("name")}
            >
              Save name
            </Button>
          </div>

          {user.last_login_at && (
            <p className="text-[11px] text-text-muted">
              Last sign-in · {formatDateTime(user.last_login_at)}
            </p>
          )}
        </CardBody>
      </Card>

      {/* Preferences */}
      <Card className="mk-fade-up" style={{ animationDelay: "60ms" }}>
        <CardHeader>
          <CardTitle>Preferences</CardTitle>
        </CardHeader>
        <CardBody className="space-y-4">
          <p className="text-[11px] text-text-muted">
            Personal defaults — independent from workspace localization.
          </p>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Language">
              <select className="mk-input" value={locale} onChange={(e) => setLocale(e.target.value)}>
                {LOCALES.map((l) => (
                  <option key={l.value} value={l.value}>
                    {l.label}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="Timezone">
              <select
                className="mk-input"
                value={timezone}
                onChange={(e) => setTimezone(e.target.value)}
              >
                {!TIMEZONES.includes(timezone) && (
                  <option value={timezone}>{timezone}</option>
                )}
                {TIMEZONES.map((tz) => (
                  <option key={tz} value={tz}>
                    {tz}
                  </option>
                ))}
              </select>
            </Field>
          </div>
          <div className="flex justify-end">
            <Button
              type="button"
              size="sm"
              disabled={!prefsDirty}
              loading={updateMe.isPending}
              onClick={() => saveProfile("prefs")}
            >
              Save preferences
            </Button>
          </div>
        </CardBody>
      </Card>

      {/* Security */}
      <Card className="mk-fade-up" style={{ animationDelay: "120ms" }}>
        <CardHeader>
          <CardTitle>Security</CardTitle>
        </CardHeader>
        <CardBody className="space-y-3">
          <div className="flex items-center justify-between gap-3 rounded-lg bg-surface-raised px-3 py-2.5">
            <div className="flex items-center gap-2.5">
              {user.mfa_enabled ? (
                <ShieldCheck size={16} className="text-success" />
              ) : (
                <Shield size={16} className="text-text-muted" />
              )}
              <div>
                <p className="text-xs font-semibold text-text">Two-factor authentication</p>
                <p className="text-[11px] text-text-muted">
                  {user.mfa_enabled
                    ? "Enabled on your identity provider"
                    : "Not enabled yet — coming soon for email accounts"}
                </p>
              </div>
            </div>
            <Badge tone={user.mfa_enabled ? "success" : "muted"}>
              {user.mfa_enabled ? "On" : "Off"}
            </Badge>
          </div>
          <div className="flex items-center gap-2.5 rounded-lg bg-surface-raised px-3 py-2.5">
            <KeyRound size={16} className="text-text-muted" />
            <div>
              <p className="text-xs font-semibold text-text">Sign-in method</p>
              <p className="text-[11px] text-text-muted">{providerLabel(user.auth_provider)}</p>
            </div>
          </div>
        </CardBody>
      </Card>

      <PasswordSection />

      {/* Connected accounts */}
      <Card>
        <CardHeader>
          <CardTitle>Connected accounts</CardTitle>
        </CardHeader>
        <CardBody>
          <div className="flex items-center justify-between gap-3 rounded-lg border border-border px-3 py-2.5">
            <div className="flex items-center gap-3">
              <span className="flex h-8 w-8 items-center justify-center rounded-full bg-surface-raised text-xs font-bold text-text">
                G
              </span>
              <div>
                <p className="text-xs font-semibold text-text">Google</p>
                <p className="text-[11px] text-text-muted">
                  {user.auth_provider === "google"
                    ? `Linked · ${user.email}`
                    : "Not linked to this account"}
                </p>
              </div>
            </div>
            {user.auth_provider === "google" ? (
              <span className="flex items-center gap-1 text-[11px] font-medium text-success">
                <Check size={12} /> Connected
              </span>
            ) : (
              <span className="text-[11px] text-text-muted">—</span>
            )}
          </div>
        </CardBody>
      </Card>

      {/* Workspaces */}
      <Card>
        <CardHeader>
          <CardTitle>Your workspaces</CardTitle>
        </CardHeader>
        <CardBody className="space-y-1.5">
          {meWorkspaces.length === 0 ? (
            <p className="text-xs text-text-muted">No workspaces yet.</p>
          ) : (
            meWorkspaces.map((ws) => {
              const active = ws.id === workspaceId;
              return (
                <div
                  key={ws.id}
                  className={cn(
                    "flex items-center justify-between gap-3 rounded-lg px-3 py-2.5",
                    active ? "bg-primary-muted/40" : "bg-surface-raised",
                  )}
                >
                  <div className="min-w-0">
                    <p className="truncate text-xs font-semibold text-text">{ws.name}</p>
                    <p className="truncate text-[11px] text-text-muted">
                      {ws.slug}
                      {ws.role_name ? ` · ${ws.role_name}` : ""}
                    </p>
                  </div>
                  {active && <Badge tone="info">Current</Badge>}
                </div>
              );
            })
          )}
        </CardBody>
      </Card>
    </div>
  );
}
