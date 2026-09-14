# Native releases and updates

The repository now contains the build, packaging and publication implementation.
It does not contain private signing credentials or a previously tested signed
release. The owner-approved **Developer ID Application: Yapio (4KH7528725)**
identity was securely exported and provisioned in the stable AWS secret, then
reread and verified. The owner-supplied Team API key also passed a read-only
`notarytool history` authentication check, without any release upload, and its
notarization credentials were imported and reread successfully in the same stable
secret. The separately approved stable update key was generated in that secret;
only its public counterpart is recorded in the repository. See the
[credential runbook](release-credentials.md).
CI-role certificate access, a real notarization submission, Windows signing,
the downloads distribution and physical-machine acceptance must still be verified
before public release. The package command deliberately fails if signing is
unconfigured. The local development DMG remains ad-hoc signed, not notarized.

## Production rollout checkpoint — 2026-09-14

This checkpoint distinguishes reviewed source from infrastructure actually changed.
It is not an approval to publish or a claim of complete product acceptance.

| Boundary | Verified state | Remaining action |
| --- | --- | --- |
| Certificate and DNS validation | The certificate-only plan was approved and applied in account `660601648321`; ACM issued the `downloads.mokaid.com` certificate in `us-east-1`. Its validation CNAME was added and reread in Hostinger. | Keep the validation CNAME for renewal. |
| Download infrastructure | An approved targeted apply created **12 of 16** planned resources: certificate validation, S3 and its controls, the unavailable object, two publisher roles, and CloudFront cache/header/OAC configuration. | AWS refused the distribution with **403: account verification required**. CloudFront, two publisher inline policies and the bucket policy remain uncreated. Contact AWS Support; do not retry creation or invent a substitute hostname. Add the separate `downloads` CNAME only after CloudFront really exists. |
| Application deploy permissions | After explicit approval, the reviewed bootstrap plan was applied: **0 created, 1 changed, 0 destroyed**. Only the existing `mokaid-github-deploy` inline policy changed in place. | Validate CI-role task registration and deployment separately; this IAM change did not update any ECS service. |
| Apple signing credentials | The exact owner-approved Developer ID identity, designated authenticated Team API key and separately approved stable update seed were provisioned in the stable AWS secret and reread successfully. Only the update public key is recorded in the repository; beta remains unconfigured. | Validate CI-role access and real notarization. Credential provisioning does not establish either. |
| Stable Mac signing role | The separately approved `mokaid-desktop-signing-stable` role and its sole inline policy were created: **2 added, 0 changed, 0 destroyed**. IAM read-back confirms the exact GitHub environment trust and secret ARN. Policy simulation permits the Mac-secret read and denies both writes and an out-of-scope API-secret read. The verified role/secret ARNs and update public key are configured in GitHub. | A policy simulation is not an actual GitHub OIDC signing run. Verify that separately; Windows and beta credentials remain unconfigured. |
| Production application | Deployment, migration, smoke-test and desktop-auth changes exist in source and have local checks. | No production application deployment from this implementation has been performed at this checkpoint. Existing services continue to run their prior versions. |
| Hosted CI | Commit `4996d2c` passed application CI (including four Docker builds), desktop infrastructure CI, and native CI on both platforms. Each native platform passed 13 CTest tests and complete unsigned staging. | See [exact run evidence](ci-evidence.md). Later changes require their own CI; hosted tests do not establish physical-GPU performance or signed release acceptance. |
| Image security and staging | Targeted runtime fixes and the four-image isolated smoke have real local evidence, including the worker's unchanged uvicorn startup. The authorized Hex fixes pass an unfiltered Hex 2.5.1 audit and all 230 API tests; the newly built API passed its scan and the repeated four-image staging. | See [scan scope and image IDs](../../../infra/docker/SECURITY_VALIDATION.md) and [Hex evidence](../../api/SECURITY_DEPENDENCIES.md). The final commit and exact ECR images still require their own CI/scans/staging before production deployment. |
| Public native release | A separately identified, ad-hoc signed development DMG was verified locally. | No public signed installer, update feed or release manifest has been published. Developer ID CI access, notarization, Windows signing and the full acceptance record remain gates. |

The issued certificate ARN is
`arn:aws:acm:us-east-1:660601648321:certificate/c3e9b6ed-a4af-48fe-b152-b2421ffab04f`.
The existing Hostinger validation record (public DNS metadata, not a secret) is:

```text
_014341570c12094a077461d307406607.downloads.mokaid.com
  CNAME _4b7d1b22e98597c44b3917bb219ef7d0.wzccmgtwzk.acm-validations.aws.
  TTL 300
```

CloudFront's blocked creation returned AWS request ID
`a00bcc42-6531-4886-b3fa-86acb73dddc2`. A subsequent read-only plan confirms exactly
**4 creations and 1 policy-document data read remain**, with no update, deletion
or replacement. The already issued ACM certificate is additional to the 12 new
resources. The publisher roles have no publishing inline policies yet; the S3
bucket remains public-access-blocked and has no CloudFront access policy. This is
an incomplete provisioning state, not a working download service. Preserve the
managed resources and state while account verification is resolved. Re-plan and
review against the then-current state after AWS clears the restriction; do not
reuse the pre-apply 16-resource plan. No downloads CNAME target is available yet.

The applied bootstrap policy adds `ecs:StopTask` only for tasks in `mokaid-prod`,
adds `ecs:TagResource` only for `mokaid-prod-*` task definitions during
`RegisterTaskDefinition`, restricts the existing `iam:PassRole` permission to
`ecs-tasks.amazonaws.com`, and removes the unrelated wildcard `iam:GetRole`.
Its refreshed comparison also reveals an existing source-versus-AWS difference:
the ECR push repository allowlist adds `mokaid-crm`; the same actions remain scoped
to the four named Mokaid repositories. The role, trust policy and OIDC provider
are unchanged. Terraform formatting, schema validation and TFLint passed; these
checks are not a real CI-role registration or deployment test.

The bootstrap still uses its historical, ignored local state. The plan reuses
that exact state and its lock rather than silently migrating it. Keep state and
plan files private and do not commit or upload them. Coordinate a separate,
reviewed migration to the protected remote backend before shared infrastructure
maintenance; never combine it with this narrow IAM change. Only apply the
explicitly reviewed saved plan, not a blanket production `terraform apply`.

The bootstrap, production root and standalone downloads/signing module test roots
version their `.terraform.lock.hcl`; only those four lockfiles are exempted from
the repository ignore rule. Checksums were obtained from the official registry
for `linux_amd64`, `linux_arm64`, `darwin_arm64` and `windows_amd64`. The selections
remain AWS **5.100.0**, TLS **4.3.0** (bootstrap) and Random **3.9.0** (production):
this change does not upgrade providers or rewrite infrastructure state. Use
`terraform init -lockfile=readonly` in reproducible validation/deployment jobs;
provider updates require an intentional, reviewed lockfile change.

Keep `MOKAID_DESKTOP_ONLY_BUSINESS`, `VITE_DESKTOP_ONLY_WEB` and the deployment
workflow's `MOKAID_DESKTOP_ONLY` switch false until both platforms' verified signed
downloads and feeds are available and the release acceptance gates pass. Creating
a certificate, approving an IAM plan or passing compilation does not authorize
removing the existing web experience.

## Build and test

Use Qt **6.11.2** with Core, Gui, Quick, QuickControls2, Network, WebSockets, Sql,
Concurrent, WebEngineQuick, Test and QuickTest. The deployed Qt QML asset-downloader
plugin also needs the `qttasktree` package; CI explicitly installs it. Install CMake 4.1.0, Ninja 1.13.0,
Conan 2.19.1, Node 22 and the Python packages in `distribution/requirements.txt`.
Conan uses the repository lockfile; updater frameworks and the Windows shader
compiler have independently verified SHA256 pins in `distribution/dependencies.json`.

`Desktop CI` builds on macOS and Windows, including the real updater SDK using a
new temporary test public key. It does not request signing credentials, produce
public installers or modify update feeds. Portable domain and distribution tests
run on Ubuntu, including an ASan/UBSan build of the portable engine and actual
cooked packs. The architecture checker and its regression tests run before the
native builds. CI resolves the current backend avatar catalog and web office
revision, cooks those hash-checked GLB files **before CMake configuration**, and
requires registration of the real-asset CTest. Staging reuses these exact tested
packs; it does not recook different bytes after the tests. It deploys the whole Qt runtime,
WebEngine helper, updater framework, native shaders, navigation data and asset
packs. Build logs do not replace GPU validation on physical machines.

```sh
python -m pip install -r apps/desktop/distribution/requirements.txt
python -m unittest discover -s apps/desktop/distribution/tests -v
python apps/desktop/distribution/release.py icons --output apps/desktop/build/icons
```

The icon converter uses the existing 1254-pixel brand PNG. It creates native ICNS
and a multi-resolution ICO; no generated replacement artwork is introduced.
For a local development build, keep `MOKAID_ENABLE_UPDATES=OFF`. A manual update
check then reports that updates are unavailable, and no update server is contacted.
If CMake finds a different Python environment, set `Python3_EXECUTABLE` to the
interpreter where Pillow is installed.

### Local macOS development DMG

Build with `MOKAID_DEVELOPMENT=ON`, `MOKAID_BETA=OFF` and
`MOKAID_ENABLE_UPDATES=OFF`, then cook its real assets and stage
the native bundle and create an explicitly development-only image:

```sh
python apps/desktop/distribution/release.py stage --platform macos-arm64 \
  --build apps/desktop/build/macos-debug --stage apps/desktop/build/development-stage \
  --assets apps/desktop/build/assets --qml apps/desktop/presentation \
  --qt-bin /path/to/Qt/6.11.2/macos/bin
python apps/desktop/distribution/release.py preview-macos \
  --stage apps/desktop/build/development-stage --output apps/desktop/build/development-release
```

This packages `Mokaid Development.app` and an Applications link in a DMG. It uses
an ad-hoc signature for local execution only: no Developer ID, notarization,
release evidence, cloud credentials or update feed is involved. Gatekeeper may
block redistribution to another machine. The app has automatic updates disabled,
and public packaging rejects this development stage. Its compiled application
name and bundle ID are `Mokaid Development` / `com.mokaid.desktop.development`:
settings, cache and credential storage remain separate from stable and beta.
The preview command rejects a stable or beta build; renaming an application or
rewriting its plist alone is not a safe substitute for compiling this identity.
Development builds cannot enable updates or the beta identity. This is not the signed
installer acceptance test. The staged application must already include compiled
Metal shaders, cooked navigation/assets and the deployed WebEngine helper.

## Provision once, then protect the release boundary

1. Reuse the owner's verified **Developer ID Application: Yapio (4KH7528725)**
   identity. Establish an App Store Connect **team** API key with notarization access.
   Prefer this revocable API key (`notary_key_p8`, `notary_key_id`, `notary_issuer`)
   for CI over an Apple-ID-specific application password; Apple ID passwords are
   not CI variables. The owner must explicitly approve exporting the certificate
   and private key to a password-protected P12 on a trusted machine and securely
   importing it into the channel's Secrets Manager JSON. Never print the P12,
   password or `.p8` contents, paste them into a chat, or commit them.
2. Establish Azure Artifact Signing with a public-trust certificate profile and
   an Entra application allowed to sign. Configure GitHub OIDC federation to the
   appropriate `desktop-signing-stable` / `desktop-signing-beta` environment, and
   grant the Certificate Profile Signer role only on the required profile.
3. Create different Ed25519 keys for stable and beta. Store the **32-byte private
   seed, base64 encoded**, in Secrets Manager. The corresponding 32-byte public
   key is base64 encoded in GitHub environment configuration and compiled into the
   app. The package command derives the public key and refuses mismatched secrets.
4. Use the already wired production root in
   `infra/terraform/environments/prod/desktop_downloads.tf`. It reuses the existing
   GitHub OIDC provider and the issued us-east-1 ACM certificate; public DNS remains
   in Hostinger, with no new Route53 zone or nameserver migration. Review the
   separate distribution plan and protect the GitHub release environments before
   applying it. Provisioning the download boundary does not publish any installer.
5. Configure the four GitHub environments: `desktop-signing-stable`,
   `desktop-signing-beta`, `desktop-public-stable`, `desktop-public-beta`. Require
   protected branches/tags and release-operator approval on public environments.
   Require review on signing environments as appropriate; a pull request must
   never gain access to either signing secrets or publishing roles.
6. Complete the Qt/module licensing and asset redistribution review. Add actual
   dependency license texts to the deployed application and review the generated
   SPDX file inventory. `NOASSERTION` in an SPDX inventory is not a license grant.

The AWS module creates a private, versioned, encrypted bucket, CloudFront OAC,
HTTPS-only distribution, CORS for the Mokaid website and channel-scoped OIDC roles.
The signer can read only the specified secret ARNs. The publisher cannot read
signing secrets and has no object-delete permission. Release object writes require
`If-None-Match: *`; previously published version paths cannot be overwritten.
Mutable feeds retain S3 object versions for recovery.

No secret values are stored in Terraform, GitHub variables, workflow YAML,
`GITHUB_ENV`, release metadata, logs or build artifacts. Workflows receive only
secret **ARNs**. Packaging retrieves values inside its process through AWS OIDC;
the temporary macOS keychain/P12/notary key are removed on success and failure.
Azure authenticates through OIDC and the pinned `TrustedSigning` PowerShell
module; no Azure client secret is needed.

### Secret shape

Each channel has a macOS secret and a Windows secret. They use the same update
public key within that channel; the stable and beta channels use different keys.
Both secrets have `update_ed25519_seed`. The macOS secret also requires these
string fields:

| Field | Contents |
| --- | --- |
| `developer_id_p12` | Base64 of the exported P12 bytes |
| `p12_password` | P12 encryption password |
| `developer_id_identity` | Full `Developer ID Application: …` identity |
| `developer_id_certificate_sha256` | Lowercase SHA256 fingerprint of the exact approved certificate |
| `notary_key_p8` | PEM contents of the notarization API private key |
| `notary_key_id` | Apple key identifier |
| `notary_issuer` | App Store Connect issuer identifier |

Do not paste the actual JSON into an issue, commit, shell command or chat. Enter
it through the organization's secret provisioning procedure. No production key
is generated implicitly; the operator tool below requires explicit approval to
export and provision only the existing owner-approved certificate identity.

### Owner-approved Mac identity provisioning

`distribution/provision_macos_signing.py` is a separately reviewed operator tool,
not a GitHub Action. Its native helper selects **one** approved public certificate
by SHA256 before requesting its matching private identity. It never exports the
entire login keychain. The public certificate was read and its fingerprints match:

```text
Subject: Developer ID Application: Yapio (4KH7528725)
SHA1:   CC0832274B40AE88AF44A9AB414C92554DED5A01
SHA256: c38e12abd12b6c4ab0904f096f036e63596a25527de6123d4d7a2778420ece46
Expiry: 2031-05-12 13:29:19 UTC
```

The SHA1 value is only the existing codesign identity selector; SHA256 pins the
approved certificate. A future certificate rotation requires a reviewed change
to the explicit pins, not a broad name-based keychain export.

Install the pinned distribution requirements into a dedicated virtual environment.
After operator review, inspect the **stable** destination without exporting:

```sh
python apps/desktop/distribution/provision_macos_signing.py --channel stable --profile mokaid
```

Only after explicit approval run the same command with `--apply`. It targets
`mokaid/desktop/stable/macos-signing` in account `660601648321`, region
`il-central-1`; it rejects other accounts or custom AWS endpoints. Do not duplicate
the secret into beta unless separately requested. A Keychain approval may appear;
the owner enters any requested Keychain password directly in the macOS prompt,
never in chat or a terminal command. The export helper times out after 120 seconds.

The P12 password has 48 random bytes of entropy. Secrets use private subprocess
pipes and process memory, never command arguments, environment values, logs or
unencrypted files. The stored PKCS#12 uses PBES2 AES-256 with SHA256 and 200,000 KDF
rounds. AWS Secrets Manager encrypts the complete JSON at rest. This does not
promise resistance to a compromised host or forensic zeroization of all Python/
framework memory: use a trusted owner machine and ephemeral CI signing runners.

The tool preserves existing JSON fields and does not generate Ed25519 seeds or
notarization keys. An already valid matching certificate is a no-op. Creation is
atomic; an existing secret gets a non-current version first, then an explicit
`AWSCURRENT` move conditional on the old version. It rereads and verifies the
current version and certificate before reporting success. A concurrent change,
incomplete identity or uncertain write fails closed; inspect version **metadata**
before retrying rather than printing any secret payload. If a failed conditional
move leaves a `mokaid-provision-*` staging label, review that non-current version;
do not promote it over another operator's credentials.

Give Terraform only the returned exact secret **ARN**, through
`desktop_signing_secret_arns.stable`; the signer role then gets read access only
to that ARN. The JSON and P12 never enter Terraform or GitHub. Provisioning the
certificate alone intentionally leaves packaging blocked on the real notarization
credentials and channel update-signing key. The main task has now performed the
owner-authorized stable export/import and verified the current secret at
`arn:aws:secretsmanager:il-central-1:660601648321:secret:mokaid/desktop/stable/macos-signing-8pPQkT`.
No beta copy was made. This is not yet a CI-role signing or public-release test.
Use the separate [credential runbook](release-credentials.md) for the approved P8
and the explicit update-key action; the certificate exporter never creates either.

### Notarization key setup — separate from the Developer ID certificate

Apple documents that **individual API keys cannot use notarytool**. An App Store
Connect administrator must create a **Team Key** under Users and Access →
Integrations → App Store Connect API. Team keys apply across apps, so select the
least privileged role that authorizes notarization and validate that access; do
not default to Admin for the CI key. Download its `.p8` once and store it through
the organization's secret procedure. See [Apple's API key guide](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api).

Record the real Key ID and Issuer ID alongside the private `.p8` in the signing
secret as `notary_key_id`, `notary_issuer` and `notary_key_p8`. The Issuer ID is not
the Developer Team ID `4KH7528725`. `notarytool` accepts these as `--key-id`,
`--issuer` and a private temporary `--key` file; an Apple ID password is unnecessary.
See [Apple's notarization migration note](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).
Do not invent a key, reuse an individual key or mark notarization complete because
the Developer ID certificate exists. A real accepted submission, staple and clean
machine assessment remain required.

CI imports the encrypted P12 through `macos/import_identity.m` with passwords on
stdin. It creates only a new private temporary keychain, verifies the exact
certificate fingerprint and signing ACL, restores the previous search list and
deletes the temporary keychain on failure/cleanup. The signing ACL permits only
the concrete `/usr/bin/codesign` trusted application, never a null allow-any list.
Neither P12 nor keychain password is passed to `security` in argv. This legacy
file-keychain compatibility boundary uses public Security.framework APIs and is
tested separately from Qt.

The opt-in native test generates an in-memory synthetic AES-256 P12, checks its
import, restricted ACL, persistent public identity, unchanged search list and
cleanup. It does not change system/user certificate trust. The synthetic identity
is intentionally untrusted and **does not prove a Developer ID signature or
notarization**. Run it on macOS with:

```sh
MOKAID_RUN_KEYCHAIN_TESTS=1 python -m unittest discover \
  -s apps/desktop/distribution/tests -p test_macos_keychain.py -v
```

### GitHub environment configuration (public identifiers only)

Signing environments need `MOKAID_UPDATE_PUBLIC_KEY`, `MOKAID_AWS_REGION`,
`MOKAID_SIGNING_AWS_ROLE_ARN`, `MOKAID_MACOS_SIGNING_SECRET_ARN` and
`MOKAID_WINDOWS_SIGNING_SECRET_ARN`. Windows additionally needs
`MOKAID_AZURE_CLIENT_ID`, `MOKAID_AZURE_TENANT_ID`, `MOKAID_AZURE_SUBSCRIPTION_ID`,
`MOKAID_AZURE_SIGNING_ENDPOINT`, `MOKAID_AZURE_SIGNING_ACCOUNT` and
`MOKAID_AZURE_CERTIFICATE_PROFILE`.

Public environments need `MOKAID_UPDATE_PUBLIC_KEY`, `MOKAID_AWS_REGION`,
`MOKAID_PUBLISH_AWS_ROLE_ARN`, `MOKAID_DOWNLOADS_BUCKET`, and
`MOKAID_DOWNLOADS_DISTRIBUTION_ID`. The update key must match the signing
environment for that same channel. The Terraform module emits bucket,
distribution and role identifiers to use for these settings.

## Candidate and promotion

Tags `desktop-vX.Y.Z` and `desktop-vX.Y.Z-beta.N` invoke `Desktop Release Candidate`.
The source must be reachable from `main` or `prod`. The validated tag determines
the app version and channel; a beta app has the independent identity
`com.mokaid.desktop.beta`, name `Mokaid Beta`, credentials/preferences namespace
and beta feed. Stable uses `com.mokaid.desktop`. Beta and stable are not converted
by relabeling the same application.

macOS staging creates the complete `.app`, signs nested native libraries,
frameworks, WebEngine helpers, Sparkle XPC services and the app with Hardened
Runtime, then notarizes/staples both app and DMG. Windows uses Inno Setup per-user
installation without elevation. It deploys the matching MSVC release CRT DLLs
from `VCToolsRedistDir/x64/Microsoft.VC143.CRT` next to each executable, including
WebEngine helpers; it never invokes an elevated `vc_redist.exe`. Windows 11 supplies
the Universal CRT. This app-local choice means each Mokaid security release must
also refresh vulnerable compiler runtime DLLs. The packager preserves valid
third-party Authenticode signatures byte-for-byte, signs Mokaid and unsigned PE
files, and rejects invalid or untrusted signatures instead of replacing them.
Its signing callback
signs **both** the uninstaller and outer installer through Azure Artifact Signing;
all signatures are verified and the installer must carry a trusted timestamp.
No installer is emitted successfully by an unsigned fallback.

Each final installer receives an Ed25519 signature compatible with Sparkle /
WinSparkle. A separately domain-separated Ed25519 signature authenticates the
metadata, including source commit, platform, channel, OS-signature validation and
notarization status. Checksums alone are never accepted as proof of authenticity.
The candidate job verifies both platforms and uploads identical bytes and SPDX
inventories to a **draft** GitHub release. It does not change public feeds.

After staging acceptance, create `distribution/acceptance/<version>.json` from the
intentionally incomplete template and submit it for review on the protected
default branch. The record binds the exact two installer SHA256 values and source
commit to a named reviewer, approval time and HTTPS evidence for all 12 required
checks: complete client/admin parity, office/avatars, session/cache isolation,
hostile HTML and accessibility, signed installation/upgrades on both platforms,
update recovery, the three hardware performance profiles and redistribution
licenses. Performance evidence must include the agreed budgets and measured
p95/p99 frames, memory, startup and sustained-load results; CI compilation is not
sufficient. Test reports must enumerate every screen/action, not merely state
that the shell opens. Never record `passed` for pending or partial work.

No approved acceptance record is included in the implementation. The validator
checks its structure, exact candidate linkage and evidence references; an operator
must review whether those reports really prove acceptance. Protected-branch review
and required public-environment reviewers are still mandatory.

Run `Desktop Promote Verified Candidate` **from the default branch** with the
existing tag and matching channel. The acceptance gate runs before cloud
authentication and before making the GitHub release public. Missing records,
pending checks and hashes for another build fail closed. A tag alone only creates
a draft candidate, never a public prototype. The public environment's approval is
the final promotion checkpoint. Promotion re-verifies signatures, publishes the existing
GitHub release and copies its immutable payloads to S3. Only after **both** payloads
are present and verified does it update channel XML feeds and finally release JSON.
There is no rebuild or re-sign during promotion. Failed uploads leave feeds
unchanged; interrupted feed writes can be retried safely using the same tag.
Promotion refuses to move a feed to an older version.

Locations:

```text
https://downloads.mokaid.com/releases/<version>/Mokaid-<version>-macos-arm64.dmg
https://downloads.mokaid.com/releases/<version>/Mokaid-<version>-windows-x64.exe
https://downloads.mokaid.com/<stable|beta>/macos-arm64.xml
https://downloads.mokaid.com/<stable|beta>/windows-x64.xml
https://downloads.mokaid.com/<stable|beta>/release.json
https://mokaid.com/download
```

The public download page only renders buttons after parsing a complete stable
manifest with exact trusted URLs, version and checksums. No release, malformed
metadata and network errors produce explicit unavailable/error states; the site
does not fabricate download links or claim an unreleased build can be downloaded.

## Update lifecycle and release acceptance

The composition root owns `UpdateService`. Start it after the main window is
ready, expose the manual check command, and keep its installation gate **closed**
whenever a form, draft, HTML preview or upload may contain unsaved work. Qt UI code
updates the gate on its own thread. Sparkle postpones relaunch until the gate
opens; WinSparkle denies shutdown and requests a save, allowing the user to retry.
Callbacks from WinSparkle's helper thread are queued back to the Qt thread. Never
disable the Chromium sandbox or pass Mokaid credentials into the update client.

Before approving the first public promotion, record successful results on clean
Mac M1/macOS13+ and Windows11/Intel Iris Xe machines, then a Windows/NVIDIA system:

- Install the candidate from its signed installer without a development SDK.
  Check icon, product identity, WebEngine loading, scene assets and shaders.
- Install a signed prior version, run an in-app update to the next candidate,
  preserve unsaved work, relaunch and verify account/cache migration.
- Reject a modified installer, wrong Ed25519 key, unsigned or revoked certificate,
  invalid notarization, interrupted download and insufficient disk space.
- Switch users, sleep/resume, close during download, and verify stable/beta cannot
  update one another. Verify per-user Windows installation and signed uninstall.
- Measure p95/p99 frame times and total process memory alongside WebEngine on real
  GPUs. Hosted CI success cannot establish the 60-FPS acceptance target.

For a faulty published version, stop further promotion and restore the previous
**feed/manifest object versions** through the reviewed infrastructure recovery
procedure, then invalidate only that channel in CloudFront. Do not replace an
immutable installer or force an application downgrade. Ship a new higher-version
signed repair release for machines already updated. Roll back schema-sensitive
changes only with the application migration policy established for that release.

## Verification recorded during implementation

- The distribution/CI tests cover required signing credentials, mismatched keys, package
  tampering, forged evidence, path traversal, notarization requirements, native
  icon formats, immutable uploads, upload failure ordering and feed downgrade,
  app-local CRT deployment, signature preservation/rejection, asset integrity and
  isolation of development previews from public releases, and mandatory acceptance
  evidence tied to the exact candidate with missing/unfinished checks blocked,
  cook-before-configure ordering, actual asset-test registration, reuse of tested
  packs and Metal toolchain discovery.
- The certificate provisioner additionally passes 15 tests with synthetic in-memory
  keys and fake AWS responses, including concurrent updates, idempotence, secret
  suppression and post-write version verification. The macOS importer passes its
  three unit tests and the opt-in AES-256 synthetic-keychain import/ACL test;
  this is not a real Developer ID signing or notarization acceptance result.
- Web tests cover no-release, valid links, untrusted manifest URLs and network errors.
- Terraform formatting, provider schema validation, TFLint and four mocked AWS
  tests pass. Read-only production plans were inspected: the broad plan also
  contained unrelated ECS changes and was not approved for blanket application.
  The owner-approved certificate-only plan was applied, and ACM issued the
  `downloads.mokaid.com` certificate after external DNS validation. A separately
  reviewed distribution plan contained only 16 creations and one data read. Its
  approved apply created 12 resources before AWS blocked CloudFront pending
  account verification; the diagnostic plan confirms four creations remain.
  No existing application service was changed. Public native promotion remains
  subject to the signed-installer and acceptance gates.
- A local `Mokaid-0.1.0-development-macos-arm64.dmg` was built with updates disabled
  and a compiled development identity. Its ad-hoc signature, disk-image integrity,
  autonomous login UI and 102 Mach-O images were checked; no non-system absolute
  dependency remained. This does not establish production login, signed installation
  on a clean machine, notarization or update acceptance.
- The updater compiles and its installation-gate contract test passes on macOS
  against Qt 6.11.2, both disabled and enabled with verified Sparkle 2.9.6. That test
  deliberately does not contact a feed or open an updater dialog.
- Windows native SDK execution, signed installation/updates and physical-GPU
  performance remain acceptance checks; they are not represented as already passing.
