# Private macOS GitHub OIDC signing probe

This is a technical proof of the real packaging path, **not a release candidate,
product acceptance record or permission to remove the web application**. The
workflow never creates a tag, GitHub Release, download manifest, appcast or S3
object. It has no publishing permissions. No signed `.app`, `.dmg`, detached
update signature, keychain, P12 or P8 is uploaded to GitHub artifacts.

## Status and explicit prerequisites

The code and synthetic safety tests are prepared. An actual GitHub OIDC signing
and notarization run has **not** been performed at this checkpoint. Do not
interpret local tests, credential provisioning, a successful build, an approved
job, or an all-skipped run as evidence that notarization passed.

Before a dispatch, the owner must explicitly authorize both:

1. Adding the exact `main` **branch** to the existing
   `desktop-signing-stable` environment's allowed deployment refs. Preserve its
   existing required reviewer and tag entries. No IAM change is needed: the
   existing role trusts this repository and environment. The probe itself does
   not edit environment policies, rulesets, branches or IAM.
2. Transferring only the **unsigned** intermediate `stage.tar.gz` and its manifest
   through Actions, with one-day retention. This repository is public; those
   intermediate bytes are not claimed private. They contain the deployed unsigned
   application/runtime, already-public product assets and public update key, but
   no signing credentials. If the owner forbids even this unsigned transfer,
   stop: separate build/sign runners need an independently authorized private
   transport. Do not combine compilation with OIDC to avoid that decision.

`main` currently has no branch-protection ruleset. This probe does not invent one
or silently require new repository protections. Its authorization boundary is
the **explicit exact main SHA**, checked against the workflow SHA and again after
the approval wait, plus the existing **required environment reviewer**. That
reviewer must inspect the commit, workflow/tooling changes and build/manifest
outputs before approving. A user able to approve malicious signing code is
trusted at this boundary; this is not a defense against a compromised reviewer,
repository administrator or hosted runner. A separate branch-ruleset change
would require separate approval.

Read back those environment policies and the non-secret variables before the
first authorized run. The approved stable role is
`arn:aws:iam::660601648321:role/mokaid-desktop-signing-stable`, with read access only
to the stable Mac signing secret described in [release-credentials.md](release-credentials.md).
It must not gain publishing, application-secret or credential-write permissions.
Windows, beta and CloudFront readiness are not prerequisites for this **Mac-only
private probe**, and are not validated by it.

## Execution, after authorization only

Merge the reviewed probe/tooling changes onto `main`, wait for required source
checks, obtain its exact 40-character SHA and manually dispatch
`desktop-macos-signing-probe.yml` on `main`. Supply `source_sha` equal to that
exact SHA and a numeric `version` (for example `0.1.0`). This version is a
disposable bundle version, not a tag or a released product version.

The non-privileged preflight **fails explicitly** if the event, repository,
branch, checkout, workflow revision or provided SHA is wrong. There are no
job-level `if` clauses that turn a bad dispatch into an all-skipped success.
If main moves before the signer starts, its fresh checkout comparison fails;
review and dispatch the new SHA instead of bypassing the check.

The two jobs enforce the following boundary:

- **Build:** no environment, no `id-token: write`, no AWS credentials. Pinned
  tools install Qt 6.11.2 and the verified updater SDK. The actual C++ application,
  native shaders, real asset packs and Sparkle are compiled/staged; CTest and
  offline distribution tests must succeed. Only the unsigned tar and manifest
  are uploaded. Their artifact ID, manifest SHA256, source SHA, platform,
  version, public key, run ID and attempt are tied together.
- **Sign:** required review in `desktop-signing-stable`; exact same reviewed
  source, not code from the archive. The existing archive verifier checks every
  file's bytes, safe canonical paths, safe symlinks and resource bounds **before
  OIDC**. It repeats verification into a fresh private directory before reading
  the secret. The assumed-role account, role/session name, regional endpoint,
  exact secret ARN, certificate fingerprint and public update key are checked.
  Compilation, CTest, application startup and artifact scripts never run here.
  The existing small trusted Security.framework importer is compiled by the
  packager; it imports only the pinned identity into a disposable keychain.

The production `package_macos` sequence is reused in an isolated module instance,
not duplicated and not invoked through the publishing command. Its command
boundary runs only named Apple system tools, strips AWS/OIDC/dynamic-loader
credentials from subprocess environments, captures their output and enforces
timeouts. Both application ZIP and signed DMG must receive distinct **Accepted**
notarization responses. There is no automatic retry of a timed-out submission:
Apple may already have accepted it, so inspect only its public submission
metadata through an authorized follow-up before another dispatch.

The signed application and DMG must pass strict signature and ticket checks.
The application leaf certificate is checked against the exact approved SHA256;
every Mach-O object must include ARM64 and satisfy the Apple Developer ID/team
requirement. Dependency references to a build-machine SDK are rejected. The
bundle must contain the pinned Qt frameworks, WebEngine process, Sparkle XPC
services, actual cooked assets and compiled Metal shader. This is an inventory,
linkage and signing test: **it does not execute Chromium, the UI, the GPU scene
or an update installation**.

## Evidence, privacy and cleanup

Signed bytes exist only on the ephemeral hosted signer and in Apple's authorized
notarization service. Apple receives the real application content to scan; this
is a notarization upload, not a public download/release upload. No customer
account, session or work content is included or used.

The job log/summary contains only constructed fields under the distinct schema
`com.mokaid.private-signing-probe`: source/tooling SHA, run identity, artifact
hash/size, public certificate/team, accepted notarization IDs, runtime inventory
and verification/cleanup booleans. There is **no** release `evidenceSignature`,
`edSignature`, acceptance file or retained signed binary. A domain-separated
in-memory Ed25519 sign/verify check validates the existing seed without producing
an update-feed signature. Release-promotion validation cannot consume this
schema as release evidence.

Temporary directories have mode `0700`; private files are restricted to `0600`.
The production importer deletes its keychain and restores the search list; the
probe also verifies that the search list is unchanged. Normal success/failure
removes all signed output directories before returning. Each subprocess has a
timeout and its process group is reaped on cancellation. A force-killed runner
cannot emit a verified-cleanup result; rely on hosted-runner destruction, not
on an impossible guarantee of Python memory zeroization. No private files or
raw remote error bodies are retained for debugging.

Success means the **sign job actually completed**, its probe report says
`status=verified`, both accepted submissions are present and cleanup was
verified. Check the job/step conclusions, not just the overall workflow icon.
It does not establish feature parity, physical-machine installation, signed
upgrade/recovery, target M1/Iris Xe performance, licensing acceptance, Windows
signature or public distribution availability. Existing public-release gates
remain unchanged.

## Offline validation

These commands read no real signing secrets and submit nothing to Apple:

```sh
python -m unittest discover -s apps/desktop/distribution/tests -v
python -m pytest infra/github/tests/test_macos_signing_probe_workflow.py -q
python -m mypy --strict --follow-imports=silent apps/desktop/distribution/macos_signing_probe.py
actionlint .github/workflows/desktop-macos-signing-probe.yml
```

Tests cover wrong event/ref/SHA, default no-execute behavior, provenance and
archive corruption before credential access, exact AWS endpoint/role boundary,
required runtime/version/identity/key checks, Apple rejection/malformed status,
timeouts, certificate/architecture/host-link checks, cleanup on failure and
separation of probe evidence from public release evidence. The existing archive
suite additionally exercises traversal, unsafe links, corruption and cross-run
substitution. These are synthetic tests, not claims of a real CI signing run.
