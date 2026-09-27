# Jev routing evaluation, version 1.0.0

Protocol fixed before running the scored cases on 2026-09-27 (Asia/Jerusalem).

## Scope

Compare the existing Mokaid worker dispatcher, unchanged, with a candidate Jev
routing component through the user-provided community service, www.jevai.org.
No tenant requests, files, identities or production workloads are used. No task
or agent is actually created. The key is retrieved in memory from AWS Secrets
Manager `mokaid/jev-api-key`; it is never included in a prompt or saved artifact.

## Frozen dataset

- `cases.json`: 72 fictional requests, 24 scenario families translated into EN,
  FR and HE. SHA256: `3d2c387177bf8f0eb36b523a2d59965a9ca486348e3d036092093467d95afee9`.
- 36 existing-agent, 18 missing-specialist, 12 partial-fit/user-choice and six
  vague-request cases. Nine cases contain injection attempts in metadata.
- Labels were authored and independently reviewed by separate agents before
  the API results were available. These are not human-validated production gold
  labels; translations are correlated, so there are 24 independent families.
- The vague-request gold reflects current product policy (custom_agent); it is
  not an endorsement of proposing agent creation in response to greetings.
- Repeat families at indices 0, 12 and 18, in all three languages: nine repeat
  requests per provider, 81 total. Order randomized with seed 20260927.

## Arms and fixed settings

1. **Haiku/current**: invoke the real `dispatcher.analyze` using existing worker
   credentials, config, prompt, Pydantic schema, token cap and JSON fallback.
   Capture token usage and retain raw output. Also apply a Python transcription
   of Phoenix's decision gate: existing_agent with confidence <45 becomes
   custom_agent; missing/out-of-roster IDs require heuristic fallback. This
   transcription does not execute Phoenix or its fallback heuristic.
2. **Jev/component**: one native `/api/v1/decisions` request with the same exposed
   request/roster/file fields. Ask separately for mode, best agent (including
   `__none__`), and an absolute full-fit probability for each agent. An existing
   assignment with full-fit <0.5 requires fallback. This threshold is fixed and
   uncalibrated; no tuning on scored cases. Mode and candidate answers are
   independent; custom mode discards the candidate. Partial-fit mode may have
   full-fit <0.5. Jev does not produce briefs or specialist profiles.

Jev's version is not assumed to match TypeSafe's latest model: record the
community default and any version metadata actually returned. Typed output or
confidence 1.0 is not proof of correctness or calibration.

This is a comparison of the current and proposed workflows, not a controlled
same-prompt model benchmark. In particular, the Jev candidate explicitly warns
against following instructions in metadata; the unchanged baseline does not.

## Metrics

- Strict mode + accepted agent correctness, before and after suitability gates.
- Harmful assignment: existing_agent or user_choice with an agent on a case
  whose gold is custom_agent. user_choice is not abstention in current UI.
- Unnecessary custom-agent proposal on a clear existing-agent case.
- Per-language/category results, schema/transport failure, first-attempt and
  eventual availability, repeated-case agreement, token usage and latency.
- Raw Haiku outputs remain available to inspect effects of its Phoenix gate.
- Record observed API latency including retries separately from successful
  individual attempts. Haiku generates a complete dispatch proposal and Jev
  only a routing choice: timing and cost scopes are not equivalent.
- Haiku cost is estimated using the current application's price table, not a
supplier invoice. Do not assume TypeSafe's price applies to the community API.

The observed run used version 1.0.0, archived byte-for-byte with a checked hash
as `runner-used-v1.0.0.py` beside the raw results. After the run, runner 1.0.1
adds guards for malformed fallback recommendations, sets the eventual HTTP code
correctly after a successful retry, and honors Retry-After on non-429 failures
too. No live cases were rerun or relabeled using these changes. The original
run retried 429 only; its one 502 had Retry-After=60 but was followed after one
second by the next case. This is a potential availability measurement confound;
later 429 failures also persisted across repeated 60-second waits.

### Maintained runner 1.1.0: catalog compatibility

The dispatcher now requires a catalog-backed `archetype_key` for every proposed
specialist. Runner 1.1.0 loads `agent_archetypes.json`, a snapshot of the 17 trusted
Phoenix archetypes with exactly the seven fields sent by the API: `key`, `name`,
`role_title`, `department`, `domain`, `skills`, and `description`. It adds that
catalog in memory only when a case payload omits `agent_archetypes`. An explicit
catalog, including an empty one used to test failure, is preserved. The frozen
`cases.json`, its labels/hash, and all historical results remain unchanged.

Use `--archetypes /absolute/path/to/catalog.json` to evaluate against another
trusted catalog snapshot. The manifest records the exact catalog file SHA256,
source path and entry count in addition to the dataset and runner fingerprints.
Refresh this snapshot deliberately when the application's archetype catalog
changes; the runner does not fetch production data. Jev still receives only the
request/roster/file and MCP fields used for its routing decision, since it does
not generate a specialist profile.

These new runs exercise the current guarded dispatcher, not the original
unchanged 1.0.0 baseline. `normalize_haiku` retains the historical routing
projection for comparability, but valid current results have already passed the
worker's full contract check. A rejected result is recorded as a failed analysis,
never repaired by this evaluation harness. In the current New Task UI,
`user_choice` also no longer triggers automatic assignment; the legacy harmful
proposal metric remains a conservative routing comparison, not a claim that a
partial-fit proposal starts a real agent. No new live result is implied by this
compatibility update.

## Availability and stop rules

Haiku concurrency two; Jev sequential with one second between completed cases.
The baseline has a 30-second deadline matching Phoenix's worker analysis timeout.
On Jev HTTP429, retry once after at least 60 seconds (honor longer numeric
Retry-After up to 120 seconds). Stop Jev after three consecutive failed cases;
record remaining cases as not attempted, never as wrong model decisions.
Transport errors are separated from accuracy among returned decisions. Do not
switch inference endpoints or credentials to work around a limit.

## Decision rule

Recommend replacement only with no observed routing regression, no increase in
harmful assignments or unnecessary creation, and demonstrated availability.
Even a passing component is not an end-to-end dispatcher replacement: generation
still needs the existing model. With tied or mixed quality, uncertainty, service
errors or unproven operational benefit, retain the current production behavior.
An optional future shadow evaluation is a separate recommendation, not a claim
that this experiment establishes production readiness. No automatic deployment.

## Reproduce

```sh
apps/ai-worker/.venv/bin/python apps/ai-worker/evals/jev_routing/run_eval.py \
  --output /absolute/path/to/new-results --repeats
```

Requires the existing worker dependencies, an Anthropic-enabled worker `.env`,
and the `mokaid` AWS profile with access to this one Jev secret. The command makes
billable provider calls. Fresh output directories preserve prior evidence.
The default catalog is `agent_archetypes.json` beside the runner; `--archetypes`
overrides it without changing the frozen corpus.
