# Desktop mailbox connections

The Mail screen exposes **Connect mailbox** directly, including when no mailbox is connected. Gmail opens the system browser and completes automatically in the desktop. IMAP/SMTP offers iCloud, Yahoo and Gmail app-password presets, manual server settings, TLS/STARTTLS and optional separate SMTP credentials. A mailbox can be reconnected without deleting its messages; a different email address must be added as a new mailbox.

## Authentication and storage

- Gmail uses the existing confidential Google web client on the API server. Its client ID and secret are injected from AWS Secrets Manager. No Google secret or refresh token is shipped in the desktop.
- The native callback is `https://mokaid.com/api/mail/oauth/google/callback`, registered alongside the existing web callbacks. `GOOGLE_DESKTOP_REDIRECT_URI` can override the server callback.
- OAuth uses S256 PKCE, encrypted state, a ten-minute transaction, authenticated member/workspace status polling, and cancellation. The API rechecks expiration and current user/member permissions after the Google exchange and before committing.
- Each mailbox has its own Google integration connection and encrypted refresh credentials. The account, connection and initial sync are committed together. Reconnection preserves a refresh token when Google does not return a replacement.
- Disconnect removes the mailbox's local messages/rules and clears its matching OAuth connection credentials atomically. Other accounts and providers retain their connections. A concurrent token refresh cannot restore removed credentials or overwrite a newer authorization; shared legacy references are preserved rather than clearing another mailbox's identity.
- IMAP and optional SMTP authenticate over certificate-verified TLS before credentials are saved. STARTTLS failure stops before authentication. The probes pin resolved public addresses and reject private/metadata destinations. SMTP validation does not send a message.
- Mailbox credentials use the existing AES-256-GCM Vault. Its deployed key source is the existing server secret; do not replace the encryption key without migrating existing ciphertext.
- Password fields are cleared when dialogs close or workspace/session context changes. They are not written to the desktop cache. The app only displays allowlisted account metadata.

## API contract

| Method and path | Purpose |
| --- | --- |
| `POST /api/mail/oauth/google/start` | Return `authorize_url` and `flow_id` for the current member |
| `GET /api/mail/oauth/:id` | Return `pending`, `connected` or `failed` for the initiating member |
| `DELETE /api/mail/oauth/:id` | Cancel pending authorization; report connected if it already committed |
| `GET /api/mail/oauth/google/callback` | Public, server-completed Google callback; no browser Mokaid session required |
| `POST /api/mail/accounts/imap` | Probe and connect an IMAP mailbox, optionally including SMTP |
| `PUT /api/mail/accounts/:id/imap` | Probe and replace credentials for the same saved email address |
| `DELETE /api/mail/accounts/:id` | Disconnect the mailbox and clear its unshared matching OAuth credentials |

IMAP/SMTP accepts `imap_security` and `smtp_security` as `tls` or `starttls`. Legacy `*_ssl=false` means mandatory STARTTLS. The email address supplies the default username; `smtp_username` and `smtp_password` optionally override incoming credentials.

## Synchronization

The initial sync starts after connection. Gmail/Graph continuation pages and IMAP UIDVALIDITY are preserved; failed ingestion never advances the cursor. Transient errors recover through the five-minute polling sweep; authentication failures require reconnecting. The desktop refreshes sync status after connecting or requesting a sync.

Authenticated Gmail push is supported by verifying Google's RS256 signature, issuer, expiry, exact audience and the configured service-account email. Set `GMAIL_PUBSUB_SERVICE_ACCOUNT` to the keyless push identity and `GMAIL_PUBSUB_AUDIENCE` to the webhook URL. The notification identity needs no access to mailboxes. The same Gmail address can trigger synchronization in every workspace where it was connected.

## Verification on 25 September 2026

The existing Google client and its AWS secret references match. Gmail API is enabled. Google accepted the configured client at its token endpoint (a deliberately invalid authorization code returned `invalid_grant`; this is a configuration check, not a mailbox login). The native redirect and public home/privacy/terms links were saved in Google Cloud, and the owner account was added to the test audience.

Automatic approval review blocked two external changes: general OAuth production publication, and provisioning the keyless Pub/Sub identity/IAM binding. Explicit questions are pending in the task. Google remains in test mode until publication is approved; the topic has no push subscription, so polling is used. An OAuth production setting does not itself complete Google's restricted-scope verification.

Automated OAuth, signed push, mailbox/protocol and native UI tests cover the connection contract. Native screenshots use synthetic fixtures and are documented in [the validation notes](../artifacts/mail-desktop-2026-09-25/README.md). Real certificate-verified handshakes passed for Gmail IMAP 993, SMTP 465 and SMTP 587 STARTTLS, plus Outlook IMAP 993. No email was sent during these checks. Full mailbox login and synchronization must be distinguished from these transport checks.

The native app was rebuilt at `apps/desktop/build/macos-debug/app/Mokaid.app` and its running executable was verified to contain `MailConnectDialog` and `MailAccountsController`. Open that **Mokaid Development** app, then **Mail → Connect mailbox**. A separate older **Mokaid UI Validation** instance does not include these changes. Live native interaction was interrupted by macOS screen-capture errors, so it does not establish a real mailbox login.

The broader native page suite has an unrelated Marketplace failure. Sanitizer binaries and a trivial sanitizer smoke program both stalled before `main` on this machine; this is not a successful sanitizer run.

## Production delivery

Verified on 25 September 2026 at 10:25 UTC:

| Service | Active revision | Result |
| --- | --- | --- |
| API | `mokaid-prod-api:53` | Exact image digest verified, rollout completed, one running task, HTTP health 200 |
| Mail/AI worker | `mokaid-prod-ai-worker:47` | Exact image digest verified, rollout completed, one running task |

Migration `20260925130000_add_mail_oauth_flows_and_multiple_accounts` completed successfully before deployment. Production rejects unauthenticated OAuth starts and Gmail push requests with 401; invalid OAuth state returns a 400 HTML page with `no-store`, `no-referrer` and a restrictive content security policy. These checks do not establish a completed real mailbox authorization or synchronization. ECS container health is reported as `UNKNOWN`; API health was additionally checked through its public HTTP endpoint and load balancer.

The release was built from production commit `03366189bf26607953b11fd842b6c9c4adb1d2ba` plus the isolated mail changes. The other work in the shared checkout was excluded. The final disconnect regressions pass, and the API image passed an offline runtime smoke test. Temporary Docker registry credentials were removed after the image pushes.

- [Production verification receipt](../artifacts/mail-desktop-2026-09-25/production-verification.json)
- [Build/source manifest](../artifacts/mail-desktop-2026-09-25/release-manifest.json) — immutable snapshot taken before the push; production state is recorded separately in the receipt above.
- [Reproducible server patch](../artifacts/mail-desktop-2026-09-25/mail-server-release.patch) — applies to the production commit and reproduces all 31 overlaid file hashes.

## Provider references

- [Google web-server OAuth and credential handling](https://developers.google.com/identity/protocols/oauth2/web-server)
- [Google Gmail scopes](https://developers.google.com/workspace/gmail/api/auth/scopes)
- [Google authenticated Pub/Sub push](https://cloud.google.com/pubsub/docs/authenticate-push-subscriptions)
- [Apple iCloud settings](https://support.apple.com/en-ie/102525)
- [Yahoo IMAP/SMTP settings](https://help.yahoo.com/kb/SLN4075.html)
