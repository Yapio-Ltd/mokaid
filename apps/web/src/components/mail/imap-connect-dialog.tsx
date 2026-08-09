import { useState } from "react";
import { Loader2, Mail } from "lucide-react";
import { useCreateImapAccount } from "@/api/hooks";
import { ApiError } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Field } from "@/components/ui/field";

interface ImapConnectDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onConnected?: (email: string) => void;
}

/**
 * IMAP/SMTP mailbox connection form. Credentials are verified against the
 * IMAP server before the account is saved (Vault-encrypted server-side).
 */
export function ImapConnectDialog({ open, onOpenChange, onConnected }: ImapConnectDialogProps) {
  const createAccount = useCreateImapAccount();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [imapHost, setImapHost] = useState("");
  const [imapPort, setImapPort] = useState("993");
  const [username, setUsername] = useState("");
  const [smtpHost, setSmtpHost] = useState("");
  const [smtpPort, setSmtpPort] = useState("587");
  const [showAdvanced, setShowAdvanced] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const canSubmit =
    /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim()) &&
    password.length > 0 &&
    imapHost.trim().length > 0 &&
    !createAccount.isPending;

  const submit = async () => {
    if (!canSubmit) return;
    setError(null);
    try {
      const result = await createAccount.mutateAsync({
        email_address: email.trim(),
        password,
        imap_host: imapHost.trim(),
        imap_port: Number(imapPort) || 993,
        username: username.trim() || undefined,
        smtp_host: smtpHost.trim() || undefined,
        smtp_port: Number(smtpPort) || undefined,
      });
      onConnected?.(result.data.email_address);
      onOpenChange(false);
      setPassword("");
    } catch (err) {
      setError(
        err instanceof ApiError
          ? err.message
          : "The connection could not be verified. Check the settings and try again.",
      );
    }
  };

  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      title="Connect a mailbox (IMAP)"
      description="Works with any email provider. Your password is encrypted and only used to sync your inbox."
      footer={
        <div className="flex w-full items-center justify-end gap-2">
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button onClick={submit} disabled={!canSubmit}>
            {createAccount.isPending ? (
              <>
                <Loader2 size={14} className="animate-spin" /> Verifying…
              </>
            ) : (
              <>
                <Mail size={14} /> Connect
              </>
            )}
          </Button>
        </div>
      }
    >
      <div className="space-y-3">
        <Field label="Email address">
          <input
            type="email"
            className="mk-input w-full"
            placeholder="you@company.com"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            autoComplete="email"
          />
        </Field>
        <Field label="Password or app password">
          <input
            type="password"
            className="mk-input w-full"
            placeholder="••••••••"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="new-password"
          />
        </Field>
        <div className="grid grid-cols-[1fr_92px] gap-2">
          <Field label="IMAP server">
            <input
              type="text"
              className="mk-input w-full"
              placeholder="imap.company.com"
              value={imapHost}
              onChange={(e) => setImapHost(e.target.value)}
            />
          </Field>
          <Field label="Port">
            <input
              type="text"
              inputMode="numeric"
              className="mk-input w-full"
              value={imapPort}
              onChange={(e) => setImapPort(e.target.value)}
            />
          </Field>
        </div>

        <button
          type="button"
          className="text-xs font-medium text-primary-light hover:underline"
          onClick={() => setShowAdvanced((v) => !v)}
        >
          {showAdvanced ? "Hide advanced settings" : "Advanced settings (username, SMTP)"}
        </button>

        {showAdvanced && (
          <div className="space-y-3">
            <Field label="Username (if different from email)">
              <input
                type="text"
                className="mk-input w-full"
                placeholder={email || "username"}
                value={username}
                onChange={(e) => setUsername(e.target.value)}
              />
            </Field>
            <div className="grid grid-cols-[1fr_92px] gap-2">
              <Field label="SMTP server (optional)">
                <input
                  type="text"
                  className="mk-input w-full"
                  placeholder="smtp.company.com"
                  value={smtpHost}
                  onChange={(e) => setSmtpHost(e.target.value)}
                />
              </Field>
              <Field label="Port">
                <input
                  type="text"
                  inputMode="numeric"
                  className="mk-input w-full"
                  value={smtpPort}
                  onChange={(e) => setSmtpPort(e.target.value)}
                />
              </Field>
            </div>
          </div>
        )}

        {error && (
          <p className="rounded-lg border border-danger/30 bg-danger/10 px-3 py-2 text-xs text-danger">
            {error}
          </p>
        )}
      </div>
    </Dialog>
  );
}
