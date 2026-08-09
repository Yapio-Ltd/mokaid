import { useMemo, useState } from "react";
import {
  AlertTriangle,
  BellRing,
  CheckCircle2,
  Loader2,
  Mail,
  Paperclip,
  Plus,
  RefreshCw,
  Sparkles,
  Trash2,
} from "lucide-react";
import {
  useCreateMailRule,
  useDeleteMailAccount,
  useDeleteMailRule,
  useGoogleOauthStart,
  useIntegrations,
  useMailAccounts,
  useMailMessage,
  useMailMessages,
  useMailRules,
  useMicrosoftOauthStart,
  useSyncMailAccount,
  useUpdateMailRule,
} from "@/api/hooks";
import type { MailAccount, MailMessage, MailRule } from "@/api/types";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { DetailPanel } from "@/components/ui/detail-panel";
import { PageHeader } from "@/components/ui/page-header";
import { SearchInput } from "@/components/ui/search-input";
import { IntegrationLogo } from "@/components/integrations/integration-logo";
import { ImapConnectDialog } from "@/components/mail/imap-connect-dialog";
import { cn } from "@/lib/cn";
import { formatRelative } from "@/lib/format";
import { toast } from "@/stores/toast-store";

/* ─── Helpers ─── */

function importanceTone(importance: number | null): "danger" | "warning" | "info" | "muted" {
  if (importance == null) return "muted";
  if (importance >= 85) return "danger";
  if (importance >= 70) return "warning";
  if (importance >= 40) return "info";
  return "muted";
}

function providerLabel(provider: MailAccount["provider"]): string {
  if (provider === "gmail") return "Gmail";
  if (provider === "microsoft") return "Outlook";
  return "IMAP";
}

/* ─── Accounts card ─── */

function AccountsCard({ accounts }: { accounts: MailAccount[] }) {
  const googleStart = useGoogleOauthStart();
  const microsoftStart = useMicrosoftOauthStart();
  const syncAccount = useSyncMailAccount();
  const deleteAccount = useDeleteMailAccount();
  const { data: integrationsData } = useIntegrations();
  const [imapOpen, setImapOpen] = useState(false);
  const [syncingId, setSyncingId] = useState<string | null>(null);

  const providers = integrationsData?.data.providers ?? [];
  const logoFor = (key: string) => providers.find((p) => p.key === key)?.logo_url;

  const connectGmail = async () => {
    try {
      const result = await googleStart.mutateAsync({
        redirect_uri: `${window.location.origin}/oauth/google/callback`,
        provider_key: "gmail",
      });
      window.location.href = result.data.authorize_url;
    } catch {
      toast({
        tone: "error",
        title: "Google OAuth unavailable",
        description: "Google OAuth is not configured on this environment.",
      });
    }
  };

  const connectMicrosoft = async () => {
    try {
      const result = await microsoftStart.mutateAsync(
        `${window.location.origin}/oauth/microsoft/callback`,
      );
      window.location.href = result.data.authorize_url;
    } catch {
      toast({
        tone: "error",
        title: "Microsoft OAuth unavailable",
        description: "Microsoft OAuth is not configured on this environment.",
      });
    }
  };

  const syncNow = async (id: string) => {
    setSyncingId(id);
    try {
      await syncAccount.mutateAsync(id);
      toast({ tone: "success", title: "Sync queued", description: "New mail arrives shortly." });
    } finally {
      setSyncingId(null);
    }
  };

  return (
    <div className="mk-card space-y-3 p-4">
      <div className="flex items-center justify-between">
        <h2 className="text-xs font-bold uppercase tracking-wider text-text-secondary">
          Connected mailboxes
        </h2>
      </div>

      {accounts.length === 0 && (
        <p className="text-xs leading-relaxed text-text-muted">
          Connect a mailbox so your AI agents can read, analyze and alert you on important email.
        </p>
      )}

      <div className="space-y-2">
        {accounts.map((account) => (
          <div
            key={account.id}
            className="flex items-center gap-2.5 rounded-lg bg-surface-raised/60 p-2.5"
          >
            {account.provider === "imap" ? (
              <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-surface-overlay text-text-secondary">
                <Mail size={15} />
              </span>
            ) : (
              <IntegrationLogo
                providerKey={account.provider === "gmail" ? "gmail" : "outlook"}
                logoUrl={logoFor(account.provider === "gmail" ? "gmail" : "outlook")}
                name={providerLabel(account.provider)}
                size="sm"
                onDark
              />
            )}
            <div className="min-w-0 flex-1">
              <p className="truncate text-xs font-semibold text-text">{account.email_address}</p>
              <p className="flex items-center gap-1.5 text-[10px] text-text-muted">
                {providerLabel(account.provider)}
                {account.status === "error" ? (
                  <Badge tone="danger">error</Badge>
                ) : account.last_sync_at ? (
                  <>· synced {formatRelative(account.last_sync_at)}</>
                ) : (
                  <>· first sync pending</>
                )}
              </p>
            </div>
            <button
              type="button"
              title="Sync now"
              className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
              onClick={() => syncNow(account.id)}
            >
              {syncingId === account.id ? (
                <Loader2 size={13} className="animate-spin" />
              ) : (
                <RefreshCw size={13} />
              )}
            </button>
            <button
              type="button"
              title="Disconnect"
              className="rounded-md p-1.5 text-text-muted transition-colors hover:bg-danger/15 hover:text-danger"
              onClick={() => deleteAccount.mutate(account.id)}
            >
              <Trash2 size={13} />
            </button>
          </div>
        ))}
      </div>

      <div className="grid grid-cols-3 gap-2">
        <Button size="sm" variant="secondary" onClick={connectGmail}>
          Gmail
        </Button>
        <Button size="sm" variant="secondary" onClick={connectMicrosoft}>
          Microsoft
        </Button>
        <Button size="sm" variant="secondary" onClick={() => setImapOpen(true)}>
          IMAP
        </Button>
      </div>

      <ImapConnectDialog
        open={imapOpen}
        onOpenChange={setImapOpen}
        onConnected={(email) =>
          toast({ tone: "success", title: "Mailbox connected", description: email })
        }
      />
    </div>
  );
}

/* ─── Rules card ─── */

const ruleActions = [
  { key: "notify", label: "In-app notification" },
  { key: "notify_email", label: "Notification + email alert" },
  { key: "label", label: "Label only" },
] as const;

function RulesCard({ rules }: { rules: MailRule[] }) {
  const createRule = useCreateMailRule();
  const updateRule = useUpdateMailRule();
  const deleteRule = useDeleteMailRule();
  const [prompt, setPrompt] = useState("");
  const [action, setAction] = useState<string>("notify");

  const submit = async () => {
    const text = prompt.trim();
    if (text.length < 3) return;
    // The rule name is a compact version of the prompt itself.
    const name = text.length > 60 ? `${text.slice(0, 57)}…` : text;
    try {
      await createRule.mutateAsync({ name, prompt: text, action });
      setPrompt("");
      toast({
        tone: "success",
        title: "Rule active",
        description: "Every new email is now checked against it.",
      });
    } catch {
      toast({ tone: "error", title: "Could not create the rule" });
    }
  };

  return (
    <div className="mk-card space-y-3 p-4">
      <div>
        <h2 className="text-xs font-bold uppercase tracking-wider text-text-secondary">
          AI mail rules
        </h2>
        <p className="mt-1 text-[11px] leading-relaxed text-text-muted">
          Tell the agent what matters, in plain language. It checks every incoming email.
        </p>
      </div>

      <div className="space-y-2">
        <textarea
          className="mk-input min-h-[64px] w-full resize-none text-xs"
          placeholder='e.g. "Notify me whenever an invoice or receipt arrives" or "Alert me about anything urgent from clients"'
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
        />
        <div className="flex items-center gap-2">
          <select
            className="mk-input h-8 flex-1 text-xs"
            value={action}
            onChange={(e) => setAction(e.target.value)}
          >
            {ruleActions.map((a) => (
              <option key={a.key} value={a.key}>
                {a.label}
              </option>
            ))}
          </select>
          <Button
            size="sm"
            onClick={submit}
            disabled={prompt.trim().length < 3 || createRule.isPending}
          >
            {createRule.isPending ? (
              <Loader2 size={13} className="animate-spin" />
            ) : (
              <Plus size={13} />
            )}{" "}
            Add rule
          </Button>
        </div>
      </div>

      <div className="space-y-2">
        {rules.map((rule) => (
          <div key={rule.id} className="rounded-lg bg-surface-raised/60 p-2.5">
            <div className="flex items-start gap-2">
              <span
                className={cn(
                  "mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-md",
                  rule.enabled ? "bg-primary/15 text-primary-light" : "bg-surface-overlay text-text-muted",
                )}
              >
                <BellRing size={11} />
              </span>
              <div className="min-w-0 flex-1">
                <p
                  className={cn(
                    "text-xs leading-snug",
                    rule.enabled ? "text-text" : "text-text-muted line-through",
                  )}
                >
                  {rule.prompt}
                </p>
                <p className="mt-1 flex flex-wrap items-center gap-1.5 text-[10px] text-text-muted">
                  <Badge tone={rule.enabled ? "primary" : "muted"}>
                    {ruleActions.find((a) => a.key === rule.action)?.label ?? rule.action}
                  </Badge>
                  {rule.matches_count > 0 && <span>{rule.matches_count} matches</span>}
                </p>
              </div>
              <button
                type="button"
                title={rule.enabled ? "Disable" : "Enable"}
                className="rounded-md p-1 text-text-muted transition-colors hover:bg-surface-hover hover:text-text"
                onClick={() => updateRule.mutate({ id: rule.id, enabled: !rule.enabled })}
              >
                <CheckCircle2
                  size={13}
                  className={rule.enabled ? "text-success" : "text-text-muted"}
                />
              </button>
              <button
                type="button"
                title="Delete rule"
                className="rounded-md p-1 text-text-muted transition-colors hover:bg-danger/15 hover:text-danger"
                onClick={() => deleteRule.mutate(rule.id)}
              >
                <Trash2 size={13} />
              </button>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ─── Message feed ─── */

function MessageRow({
  message,
  selected,
  onSelect,
}: {
  message: MailMessage;
  selected: boolean;
  onSelect: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onSelect}
      className={cn(
        "flex w-full items-start gap-3 rounded-xl p-3 text-left transition-all",
        selected ? "bg-primary/10 ring-1 ring-primary/40" : "bg-surface-raised/50 hover:bg-surface-hover",
      )}
    >
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <p className="truncate text-xs font-semibold text-text">
            {message.from_name || message.from_email || "Unknown sender"}
          </p>
          {message.ai_importance != null && (
            <Badge tone={importanceTone(message.ai_importance)}>{message.ai_importance}</Badge>
          )}
          {message.ai_category && <Badge tone="muted">{message.ai_category}</Badge>}
          {message.has_attachments && <Paperclip size={11} className="shrink-0 text-text-muted" />}
          <span className="ml-auto shrink-0 text-[10px] text-text-muted">
            {message.received_at ? formatRelative(message.received_at) : ""}
          </span>
        </div>
        <p className="mt-0.5 truncate text-xs text-text-secondary">
          {message.subject || "(no subject)"}
        </p>
        {(message.ai_summary || message.snippet) && (
          <p className="mt-0.5 line-clamp-1 text-[11px] text-text-muted">
            {message.ai_summary ? (
              <>
                <Sparkles size={10} className="mr-1 inline text-primary-light" />
                {message.ai_summary}
              </>
            ) : (
              message.snippet
            )}
          </p>
        )}
      </div>
    </button>
  );
}

function MessageDetail({ messageId, onClose }: { messageId: string | null; onClose: () => void }) {
  const { data } = useMailMessage(messageId);
  const message = data?.data;

  return (
    <DetailPanel open={Boolean(messageId)} onClose={onClose} title={message?.subject || "Email"}>
      {message && (
        <div className="space-y-4 px-5 py-4">
          <div className="space-y-1 text-xs">
            <p className="text-text">
              <span className="text-text-muted">From </span>
              {message.from_name || ""}{" "}
              <span className="text-text-secondary">&lt;{message.from_email}&gt;</span>
            </p>
            {message.received_at && (
              <p className="text-text-muted">{new Date(message.received_at).toLocaleString()}</p>
            )}
            <div className="flex flex-wrap items-center gap-1.5 pt-1">
              {message.ai_importance != null && (
                <Badge tone={importanceTone(message.ai_importance)}>
                  Importance {message.ai_importance}
                </Badge>
              )}
              {message.ai_category && <Badge tone="muted">{message.ai_category}</Badge>}
            </div>
          </div>

          {message.ai_summary && (
            <div className="rounded-lg border border-primary/25 bg-primary/5 px-3 py-2">
              <p className="flex items-start gap-1.5 text-xs leading-relaxed text-text-secondary">
                <Sparkles size={12} className="mt-0.5 shrink-0 text-primary-light" />
                {message.ai_summary}
              </p>
            </div>
          )}

          <div className="whitespace-pre-wrap break-words text-xs leading-relaxed text-text-secondary">
            {message.body_text || message.snippet || "No content."}
          </div>
        </div>
      )}
    </DetailPanel>
  );
}

/* ─── Page ─── */

export function MailPage() {
  const { data: accountsData, isLoading: accountsLoading } = useMailAccounts();
  const { data: rulesData } = useMailRules();
  const [search, setSearch] = useState("");
  const [importantOnly, setImportantOnly] = useState(false);
  const [selectedId, setSelectedId] = useState<string | null>(null);

  const filters = useMemo(
    () => ({
      q: search || undefined,
      min_importance: importantOnly ? 70 : undefined,
      limit: 100,
    }),
    [search, importantOnly],
  );
  const { data: messagesData, isLoading: messagesLoading } = useMailMessages(filters);

  const accounts = accountsData?.data ?? [];
  const rules = rulesData?.data ?? [];
  const messages = messagesData?.data ?? [];

  return (
    <div className="flex h-full gap-5">
      <div className="min-w-0 flex-1 space-y-5">
        <PageHeader
          title="Mail"
          subtitle="Your AI mail agent — synced inboxes, smart analysis and instant alerts."
          actions={
            <div className="flex items-center gap-2">
              <Button
                size="sm"
                variant={importantOnly ? "primary" : "secondary"}
                onClick={() => setImportantOnly((v) => !v)}
              >
                <AlertTriangle size={13} /> Important
              </Button>
              <SearchInput
                placeholder="Search mail…"
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                className="w-56"
              />
            </div>
          }
        />

        {accounts.length === 0 && !accountsLoading ? (
          <div className="mk-card flex flex-col items-center gap-3 p-10 text-center">
            <span className="flex h-12 w-12 items-center justify-center rounded-2xl bg-primary/15 text-primary-light">
              <Mail size={22} />
            </span>
            <div>
              <h2 className="text-sm font-bold text-text">No mailbox connected yet</h2>
              <p className="mx-auto mt-1 max-w-sm text-xs leading-relaxed text-text-muted">
                Connect Gmail, Microsoft or any IMAP mailbox on the right. Your AI agents will
                sync incoming mail, score importance and alert you on what matters.
              </p>
            </div>
          </div>
        ) : (
          <div className="space-y-2">
            {messagesLoading && messages.length === 0 && (
              <div className="mk-card flex items-center justify-center gap-2 p-8 text-xs text-text-muted">
                <Loader2 size={14} className="animate-spin" /> Loading messages…
              </div>
            )}
            {!messagesLoading && messages.length === 0 && (
              <div className="mk-card p-8 text-center text-xs text-text-muted">
                No messages synced yet. New email shows up here right after the first sync.
              </div>
            )}
            {messages.map((message) => (
              <MessageRow
                key={message.id}
                message={message}
                selected={selectedId === message.id}
                onSelect={() => setSelectedId(message.id)}
              />
            ))}
          </div>
        )}
      </div>

      <div className="hidden w-[320px] shrink-0 space-y-4 lg:block">
        <AccountsCard accounts={accounts} />
        <RulesCard rules={rules} />
      </div>

      <MessageDetail messageId={selectedId} onClose={() => setSelectedId(null)} />
    </div>
  );
}
