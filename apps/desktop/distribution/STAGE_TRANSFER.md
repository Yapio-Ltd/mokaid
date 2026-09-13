# Unsigned build → protected signer

The release workflow separates native compilation from signing authority:

1. `metadata` validates the release version, records the source commit and freezes
   the current authorized `main`/`prod` commit used for signing tooling.
2. `build_macos` and `build_windows` compile, cook, test and stage the exact source
   commit with `contents: read` only, no environment and no OIDC permission.
3. Each build produces `stage.tar.gz` and `stage-manifest.json`. Tar preserves
   executable modes and relative framework symlinks which direct artifact upload
   would not preserve. Each platform exposes its immutable artifact ID and the
   manifest SHA256 as separate job outputs.
4. `sign` starts only after both builds finish and the signing environment reviewer
   approves. It checks out the frozen **signing-tooling commit**, downloads the
   exact platform artifact ID from the current run and verifies the build's
   manifest digest. It never imports or executes build scripts from the archive.
5. `stage_archive.py restore` checks repository, run ID, attempt, platform, version,
   channel, source/tooling commits, public key, archive hash and every file's hash,
   size and permissions before extracting anything. It rejects traversal, external
   or cyclic links, links used as parent directories, hardlinks, device files,
   Windows reserved names, duplicate/case-colliding paths and oversized metadata.
   It writes ordinary files into a temporary tree, creates internal symlinks last,
   compares the resulting inventory, then renames the verified tree into place.
6. Only the signing job can request AWS/Azure OIDC identities. It packages the
   verified stage with trusted tooling. The final candidate job verifies both
   platform signatures/evidence and creates a draft, never advances public feeds.

`ci.json` is reconstructed from validated identity fields, not imported from the
build. No absolute build paths, SDK paths, commands or arbitrary configuration are
accepted in the transfer manifest. Resource caps are 100,000 files, 12 GiB unpacked,
8 GiB compressed and 32 MiB manifest; individual tar metadata reads are bounded.

## Versioned public update keys

`update-public-keys.json` is public source, with exactly:

```json
{"schemaVersion": 1, "stable": null, "beta": null}
```

An uninitialized channel deliberately prevents a public release. Once the real
private signing key has been securely provisioned, commit **only its exported
canonical base64 32-byte Ed25519 public key** for the appropriate channel before
tagging that release. Never commit a private seed or key. A length/encoding check
cannot distinguish a public key from a mistakenly pasted same-length private seed.

The build reads this versioned file. The signer compares the manifest's public key
with both its reviewed tooling file and the environment's `MOKAID_UPDATE_PUBLIC_KEY`.
All three must agree; a rotation or branch change causing a mismatch fails closed.
The protected package verifier additionally checks the deployed product's release
identity. The keys remain `null` until actually provisioned and reviewed.

## Operator approval and retry

Approve only after reviewing the source SHA, frozen tooling SHA, workflow source
and artifact identity. A tag-supplied ancestry check remains mutable by a tag
writer; it does not replace the environment gate or planned branch/tag rulesets.
Administrators can ultimately change those controls. Signing tools/dependencies
inside the signing job are trusted code; OIDC is a job-wide permission, not limited
to its later login step.

Run/attempt identity is intentionally strict. Use **Re-run all jobs** after an
interrupted release; re-running only a failed signing job against earlier-attempt
build artifacts will fail verification. The workflow does not silently mix
artifacts across attempts or fall back from missing immutable IDs to name globs.

These are locally verified controls, not proof of a completed public release.
Real Developer ID/Azure signatures, notarization, Windows execution, clean-machine
installation and updater acceptance still require their separate release checks.

## Checks

```sh
python -m unittest discover -s apps/desktop/distribution/tests -p test_stage_archive.py -v
python -m pytest -c infra/github/pyproject.toml infra/github/tests/test_release_workflow.py
```

An optional read-only source-bundle roundtrip exercises real framework paths and
symlinks; all temporary copies are removed afterwards and no native code is run:

```sh
MOKAID_STAGE_ROUNDTRIP_FIXTURE=/absolute/path/to/staged-runtime python -m unittest discover -s apps/desktop/distribution/tests -p test_stage_archive.py -v
```

The optional fixture is a transfer test only. It does not turn an unsigned or
development build into a releasable product.
