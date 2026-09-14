# Stable release credentials: explicit owner operations

`distribution/provision_release_credentials.py` is an operator tool, not a CI
step. It only updates the existing approved stable macOS secret:

```text
arn:aws:secretsmanager:il-central-1:660601648321:secret:mokaid/desktop/stable/macos-signing-8pPQkT
```

It cannot create a secret, change IAM, provision beta, upload a release, or modify
an Apple account. Install the pinned `distribution/requirements.txt` into a
trusted Python 3.11+ environment. Apple verification requires macOS and its
installed `xcrun notarytool`. AWS imports require the owner's authorized `mokaid`
SSO profile; only the approved account and official regional endpoints are
accepted.

## Verified checkpoint — 2026-09-14

The owner-approved Developer ID certificate was exported as one encrypted
identity, imported into the stable secret and reread successfully. Its exact
SHA256 remains
`c38e12abd12b6c4ab0904f096f036e63596a25527de6123d4d7a2778420ece46`.
This helper validates that encrypted identity again and never replaces it.

The owner designated `AuthKey_PSCH3V7XQU.p8`. The main task verified this exact
file using `notarytool history` with key ID `PSCH3V7XQU` and Yapio's issuer
`0f85a409-d9b6-48e8-a7fd-bca7c471b9de`: the command succeeded without contacting
AWS or submitting anything. The file was restricted to mode `0600`. This real
authentication result, not a filename or a potentially different key visible in
Apple's UI, establishes that the supplied credentials work together. No Apple
key was created or revoked by this helper.

The main task then explicitly imported the approved notarization fields into the
same stable secret. The helper repeated Apple authentication, conditionally
promoted the new AWS version and verified its contents: `status=provisioned`,
`notaryHistoryAuthenticated=true`, `releaseUploaded=false`. The existing
certificate was preserved. The separately approved stable Ed25519 generation
also completed with `status=provisioned` and a verified current AWS version. Its
public key is now recorded in `distribution/update-public-keys.json`; beta remains
unconfigured. Only this public value is recorded here:

```text
o2RXdU+YFRb6wU/r+UpVrAvlTiftNWHkaflRwfKKuJk=
```

No private seed was printed or written to a local file. Credential provisioning
does not establish successful release
notarization, a trusted clean-machine installation, public download availability,
or CI-role access. Those remain separate checks.

The separate `distribution/probe_test.py --profile mokaid --run` was also executed
successfully against this exact AWS secret. It reused the production importer,
signed only a locally compiled harmless fixture, verified the Apple Developer ID
requirement, Team ID and exact certificate fingerprint, and ran that fixture.
The temporary keychain was removed and the owner's keychain search list was
verified unchanged. Nine mocked safety tests additionally cover this probe.
This is real certificate import/signing evidence, **not** a timestamped installer,
notarization, public release, or GitHub OIDC session test.

## 1. Metadata-only planning

The default command checks the explicit key ID, its exact `AuthKey_<ID>.p8`
filename, the approved issuer and file metadata. The file must be absolute,
owned by the operator, regular, single-link, and mode `0600`. The helper never
changes permissions implicitly. A metadata check does **not** read the key,
inspect AWS credentials or secrets, contact Apple, or generate a private key.

```sh
python apps/desktop/distribution/provision_release_credentials.py notary \
  --key-path /Users/olimservice/Downloads/AuthKey_PSCH3V7XQU.p8 \
  --key-id PSCH3V7XQU \
  --issuer 0f85a409-d9b6-48e8-a7fd-bca7c471b9de
```

Key IDs are explicit rather than compiled into this tool because Apple keys can
be revoked and recreated. A filename alone does not authenticate its contents.
Use only the file the owner actually designated; do not search Downloads for
other private keys, infer a different ID from the account UI, or print any P8
contents. The issuer is deliberately fixed to the approved Yapio team.

## 2. Read-only Apple authentication

Add `--verify-notary` to the same command. This reads only the designated P8,
rejects a replaced file, validates a single unencrypted P-256 PKCS8 key, then runs
**only** `notarytool history`. It does not contact AWS or generate a seed.

The key is supplied through a newly created `0600` temporary file inside a
`0700` directory, never through arguments or environment values. Standard input,
output and error are discarded; even historical submission details are not
printed or saved. Timeout/cancellation kills and reaps the child before removing
the temporary directory. A success response contains only public key ID, issuer
and status fields. The original owner file is not deleted.

`--verify-notary` and `--apply` are mutually exclusive. An authentication failure
must stop the operation; do not try guessed keys, change account permissions,
revoke keys or suppress the error to reach provisioning.

## 3. Import the approved notarization credentials

Only after explicit operator approval, add `--apply` instead of
`--verify-notary`. This reads the existing stable secret, validates its exact
encrypted Developer ID identity, validates the supplied P8 and authenticates with
Apple again. It adds only `notary_key_p8`, `notary_key_id` and `notary_issuer`.

If all three existing fields match the supplied values exactly, the operation is
idempotent: authentication is checked again, but nothing is written. Partial or
different credentials cause a refusal, not a silent rotation. A rotation requires
a separately reviewed procedure and authority.

The AWS write preserves **every** existing JSON field, including the encrypted
certificate, password, certificate fingerprint, update seed and unknown extension
fields. A second read rejects a concurrent change before writing. A new immutable
version is first created with a `mokaid-credentials-*` label, without `AWSCURRENT`.
Promotion explicitly removes the expected prior current version; AWS rejects a
concurrent change. The helper rereads the exact new version and full document
before reporting `provisioned`.

On an uncertain failure, inspect **version metadata only** before retrying. A
failed promotion can leave an encrypted non-current pending version. Do not
promote it over another operator's update or print its secret JSON. A successful
write followed by a failed response is safe to retry with the same owner file:
matching credentials are a no-op. There is no automatic rollback, overwrite,
secret creation or deletion.

## 4. Generate the stable update key — separate approval

The notary operation never generates an update key. Planning the separate action
also generates nothing and contacts no network:

```sh
python apps/desktop/distribution/provision_release_credentials.py generate-update-key
```

Only after explicit approval add `--apply`. If and only if
`update_ed25519_seed` is absent, the tool generates an Ed25519 key in memory and
stores its base64-encoded 32-byte seed through the same conditional promotion.
No private seed file is created. An existing valid seed is retained and its
public key is returned; an empty, malformed or invalid existing field causes a
refusal rather than replacement.

Only the base64-encoded 32-byte **public key** appears in the result. After
successful reread, an operator may commit that value in
`distribution/update-public-keys.json` under `stable`, preserving its schema and
the unrelated beta value. Configure the same public key in the corresponding
GitHub environments. The helper deliberately does not edit that file or GitHub.
Use a separately authorized process to connect this channel's seed to Windows
signing; do not duplicate it through logs, chat, CLI arguments or private files.
Beta must have a different key, not a copy of stable.

## Guarantees and remaining acceptance

Python/framework memory is not guaranteed to be forensically zeroized. Core
dumps and Python logging are disabled by the CLI, child environments exclude AWS
and dynamic-loader secrets, and operator errors omit remote response bodies.
Use a trusted owner machine; none of these controls defends against a compromised
host, privileged debugger, system crash recorder or hostile Python installation.

The synthetic suite covers private-file replacement, invalid keys, certificate
pins, Apple errors and timeouts, all three conditional-update race windows,
idempotence, exact field preservation, public/private output separation, and the
read-only/default mode boundaries. Run without real credentials:

```sh
python -m unittest discover -s apps/desktop/distribution/tests \
  -p test_provision_release_credentials.py -v
```

The initial suite passes **24 tests** with **98.72% branch/line coverage**; strict
mypy, Ruff and Black checks pass. The broader release gates still require actual
signed builds, notarized/stapled artifacts, clean-machine installation/update,
Windows signing, download distribution and protected CI-role access. Apple
documents Team API keys in its [API key guide](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
and the notary arguments in its [notarization migration note](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool).
