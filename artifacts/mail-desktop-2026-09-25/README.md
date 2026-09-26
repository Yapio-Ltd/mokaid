# Native mailbox connection validation

The PNGs in this directory are native Qt Quick captures using isolated synthetic HTTP fixtures. They show the Mail page and its connection controls without the surrounding desktop shell. No live mailbox, Google authorization or real email password was used in these fixtures.

- `mail-connect-choices.png`: Google OAuth and IMAP/SMTP entry points.
- `mail-google-browser.png`: waiting for server-confirmed Google authorization.
- `mail-imap-icloud-760.png`: iCloud preset, protected app-password field and submit action at 760×620.
- `mail-wide.png`, `mail-minimum.png`, `mail-inspector-minimum.png`: populated message view and inspector at wide/minimum sizes.

The native Mail controller tests cover server-confirmed OAuth success, cancellation and completion races, transient cancellation failures, strict browser URL validation, safe account fields, IMAP/SMTP payloads, readable server errors, reconnect identity, real account selection and sync paths, and workspace isolation. QML coverage exercises the Google flow, iCloud detection, server security values, credential clearing and minimum-size form access.

Provider settings were checked against the official [Apple](https://support.apple.com/en-ie/102525), [Yahoo](https://help.yahoo.com/kb/SLN4075.html) and [Google](https://developers.google.com/workspace/gmail/imap/imap-smtp) documentation.
