# Google connections — 27 September 2026

## Confirmed real-mail result

The production provider catalog was empty. Adding the six missing Google definitions repaired the post-consent save failure. After a new consent, the browser reported Gmail connected and the initiating desktop closed its dialog and displayed one mailbox. A read-only production check confirmed an active Gmail account and 25 synchronized messages. No email was sent.

- [Real-account verification](real-mail-verification.json)
- [Implementation and limits](../../docs/GOOGLE_CONNECTIONS.md)

## Reproducible server delivery

The isolated source snapshot starts at the active production commit `4716998a35123c85e19bdbe2013e8f4ff3d69669`. Only the 19 files listed in the source manifest were overlaid. Concurrent Jev work and native UI changes are excluded from the server images.

- [Source manifest](release-manifest.json)
- [Server patch](google-server-release.patch), verified with reverse apply against the build source
- [Immutable published images](images.json), Linux ARM64 for the existing ECS services

The API-specific Docker ignore file was used as the isolated root ignore file because this host uses the legacy Docker builder. It includes only the existing avatar-cooker source files required by the production API Dockerfile. No local environment files or credentials were included. Temporary ECR login credentials were removed after publication.

## Validation

- 87 combined API OAuth, mailbox, access-control and managed Google-tool regression tests passed.
- 52 worker Google/MCP tests passed; Google adapter coverage 98%; mypy strict, Black and Ruff passed.
- API release modules and all six provider definitions loaded in an offline container.
- Worker offline runtime check: ARM64, unprivileged uid1000, no dependency conflicts, health OK, six Google providers and 12 read tools.
- Native build: 71 controller tests,7 shared-QML tests and47 native-page tests passed; five synthetic screenshots reviewed. See [native validation](../google-desktop-2026-09-27/validation.md).
- API57 and worker50 rollouts completed with health200 and protected OAuth routes. See [production verification](production-verification.json).

These fixture tests do not claim live Calendar/Drive reads. Google remains in Testing with two allowed accounts; general publication and restricted-scope verification remain separate requirements. Native Calendar/Files connection controls enable agent access; they do not import Google events/files into local workspace views.
