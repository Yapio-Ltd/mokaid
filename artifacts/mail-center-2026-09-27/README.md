# Desktop Mail center — 27 September 2026

The native Mail page follows the supplied three-column reference: folders and Compose, filtered/sorted messages, reader and persistent reply action. The shell search becomes a real mail search. Narrow windows use a folder selector and separate list/reader views. Gmail/IMAP connections and the Google services chooser remain available.

All records in these screenshots and transport tests are isolated fixtures. No test message was sent to a real recipient and opening Mail does not mark remote messages read.

## Runnable build

- Bundle: `/Users/olimservice/mokaid/apps/desktop/build/macos-debug/app/Mokaid.app`
- Executable: `Contents/MacOS/Mokaid`
- SHA-256: `824b875eeea8891e9287de2fee84db08a012f3bbcf630f014a245a8124d9cd92`
- Modified: `2026-09-27 01:41:09 IDT`
- Inode: `212216000`; size: `37911032` bytes.
- Full native application compilation passed. `git diff --check -- apps/desktop` passed.
- Build uses the existing Qt 6.11.2 SDK and temporary Python environment `/private/tmp/mokaid-google-sdk-tools/bin/python`. The former cached Python path no longer existed; Pillow was restored only in this temporary environment for icon generation.

## Validation

| CTest name | QtTest methods | Passed QtTest invocations, including init/cleanup |
|---|---:|---:|
| desktop-feature-contracts | 61 | 71 |
| desktop-mail-center | 10 | 12 |
| desktop-feature-qml | 5 | 7 |
| desktop-native-pages-qml | 17 | 48 |
| desktop-preview-formats | 8 | 10 |
| preview_resource_policy | 3 | 5 |
| desktop-preview-navigation | 2 | 4 |

`targeted-ctest.txt` records the broader regression batch. `final-ctest.txt` records the final Mail controller, native-page, and preview-navigation rerun, all passing. `desktop-transport-tests.txt` records the 12 controller tests including a first validation rejection and a lost response followed by forbidden access. The `*-functions.txt` files list the exact QtTest methods. These tests use loopback-only fixture APIs and an offscreen renderer.

Useful commands:

```sh
cmake --build apps/desktop/build/macos-debug --target mokaid_desktop mokaid_mail_center_tests mokaid_native_pages_qml_tests mokaid_preview_navigation_tests -j6
ctest --test-dir apps/desktop/build/macos-debug --output-on-failure -R '^(desktop-feature-contracts|desktop-mail-center|desktop-feature-qml|desktop-native-pages-qml|desktop-preview-formats|preview_resource_policy|desktop-preview-navigation)$'
```

## Screenshots

- `mail-center-wide.png`: folders, real fixture counts/labels, message categories, formatted reader and attachments.
- `mail-reply-wide.png`: reply from the original mailbox with preserved composition.
- `mail-reader-compact.png`: compact reader after the body finishes loading.
- `mail-compose-compact.png`: From/To/subject/body and fixed Attach/Send actions at 760 × 620.
- `mail-attachment-html-inert.png`: hostile HTML presented as escaped text despite a PDF name/MIME.
- `mail-attachment-pdf-native-fallback.png`: explicit download fallback when offscreen tests have no native Quick Look window.

## Behavioral and safety checks

- Message list, server pagination, folders, filters, sorting and exact label query use the mail API. Message details show hydration errors with a retry instead of silently hiding unavailable content.
- Read/unread, star, archive, spam and trash are explicit provider-backed actions. Sending/managing controls use server capabilities.
- A draft retains its account when the mailbox filter changes. Replies retain their original account. Closing the composer keeps the draft; discard is explicit. Drafts/uncertain delivery are included in workspace, quit and update protection.
- Outgoing To/Cc/Bcc, plain text and selected local attachments are bounded. The first definite validation rejection preserves an editable draft. After a lost or uncertain response, status checks retain the same request ID and submitted payload; a later 403 cannot enable a duplicate send.
- HTML bodies are parsed into inert text runs and rebuilt from an allowlist. Original tags, remote/local images, CSS resources, forms and scripts never reach the reader.
- Download is exercised end to end: the selected attachment emits `saveRequested`, the actual authenticated client requests `/api/mail/messages/message-a/attachments/part-a`, and `DriveDownload` atomically saves bytes identical to the fixture into a temporary directory, ending with `File saved.`
- Attachment preview classification inspects bytes rather than trusting MIME or extension. HTML/SVG/Markdown stay escaped text, scripts and external resource privileges are disabled, and the general native opener is unavailable for arbitrary mail attachments.
- Recognized PDF attachments use the existing macOS Quick Look helper with a private, signature-checked file forced to a `.pdf` extension. The mail PDF never enters an active WebEngine viewer. On platforms without Quick Look, the UI offers an honest download fallback. Automated tests certify the byte/signature/private-file route and fallback; they do not certify a live AppKit Quick Look window.
- The pre-existing interactive deliverable profile is preserved for workspace deliverables. Its PDF rendering, media decoding, navigation and retention tests still pass.

## Principal implementation files

- `apps/desktop/application/features/mail_center_controller.cpp` and its public header.
- `MailPage.qml`, `MailFolders.qml`, `MailMessageList.qml`, `MailReader.qml`, `MailComposer.qml`, `MailLogic.js`.
- Mail-only `DesktopShell.qml` search and `FeaturePage.qml` integration; `Main.qml` protected work.
- Additive attachment routes in `ArtifactService` and `DriveDownload`; scoped mail restrictions in `PreviewController`, `DeliveryView.qml`, document format and resource policy.
- `mail_center_tests.cpp`, native page fixtures, and preview format/navigation/policy tests.

The native design contract is recorded in `apps/desktop/DESIGN.md`.
