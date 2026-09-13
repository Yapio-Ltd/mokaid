# Release trust review — 2026-09-14

Scope: the desktop release/promote workflows, environment policy and desktop AWS
role trust. This was a read-only review plus offline tests, not a penetration
test. No tag was pushed, workflow dispatched, OIDC token minted, secret read or
production operation attempted. Findings concern repository writers or a
compromised build dependency, **not anonymous readers or ordinary fork PRs**.

## Findings and disposition

| Priority | Finding | Disposition |
| --- | --- | --- |
| High | A tag controls the workflow which checks that tag's ancestry | Add signing reviewer gate before connecting real signing secrets; tag rulesets still needed |
| High | The entire native build job can request the signing OIDC identity | Explicitly covered by operator approval now; split unprivileged build and trusted signing before broader contributor access |
| Medium | Unprotected release branches and administrator bypass weaken independent review | Separate ruleset/branch policy decision required; no silent changes |
| Low | Elevated workflow permissions lack inline rationale | Document exact use when workflows are next changed |

The high ratings describe the potential impact **after** signing credentials are
connected. At review time signing role/secret references remain unresolved; no
working signing access was demonstrated. A preliminary CVSS 3.1 model for a
repository writer gaining confidential signing material is
`CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:H/I:H/A:N` (8.1); the new required human approval
changes that attack precondition. This is not a measured production exploit.

### 1. The ancestry test is not an independent authorization boundary

Locations: `.github/workflows/desktop-release.yml:5`, `:25`, `:31`;
`infra/terraform/modules/desktop-downloads/main.tf:325`.

The release starts from a `desktop-v*` push. That ref also supplies its workflow
and local build/package code. A writer who can create a matching tag can change
the ancestry check itself. The AWS role trusts the exact repository/environment
subject, not a specific immutable workflow. Matching the environment's tag
pattern does not authenticate the code behind the tag.

The reviewed desired policy now requires Tomyshh for both signing environments,
as well as public promotion. The operator must inspect the exact commit and its
workflow/build scripts before approving; approving on name alone is insufficient.
This gate is a mitigation, not a substitute for branch/tag controls.

### 2. Late login does not make earlier build steps unprivileged

Locations: `.github/workflows/desktop-release.yml:34`, `:67`, `:69`, `:72`.

`id-token: write` belongs to the whole job. Earlier dependency installation,
native configuration and tests run with the ability to request that identity,
even though the explicit AWS login appears later. Merely moving the login step
does not isolate the credential boundary. The current reviewer must therefore
authorize all code executed in the job, including its dependencies.

Preferred follow-up: build on a job with no OIDC or signing environment, then
consume verified immutable artifacts in a separate narrowly scoped signer running
only trusted signing tooling. If signing is moved into a reusable workflow, bind
its immutable identity in a customized `sub` and the AWS trust policy; do not add
unsupported arbitrary `job_workflow_ref` IAM condition keys. A reusable workflow
which still executes arbitrary source scripts with OIDC is not sufficient.
[GitHub OIDC permissions and subject customization](https://docs.github.com/en/actions/reference/security/oidc)

### 3. Additional repository controls: proposal only

`main`/`prod` protections were absent at initial inspection. The environment API
also reports administrator bypass as enabled by default. Administrators can
ultimately edit the controls themselves; this review does not promise protection
against a fully compromised sole administrator account.

Before signing keys are connected, separately review these changes:

1. An active tag ruleset targeting `refs/tags/desktop-v*` which restricts creation
   to a named release-operator team or dedicated GitHub App. Resolve its actual
   identity first; no invented team/app IDs or broad writer-role exemption.
2. A separate tag immutability ruleset restricting updates and deletion, without
   routine bypass. Separating this from creation avoids giving an allowed creator
   implicit permission to retarget an already reviewed release.
3. Rules for `main` and `prod` blocking force pushes/deletion, requiring reviewed
   PR workflows and the actual successful CI check names. Protect workflow,
   packaging, IAM and policy ownership. Determine whether a second independent
   reviewer exists before requiring an approval count which the sole operator
   cannot satisfy on their own PR.
4. Review administrator-bypass settings in the environment UI. Keep any emergency
   bypass explicit and auditable, not an undocumented promise of independence.

Rulesets are supported on this public repository's GitHub Free organization plan.
The exact rule payload and bypass actors require a separate read-only plan and
approval; none is applied by `reconcile.py`.
[GitHub ruleset controls](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets),
[eligible bypass actors](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/creating-rulesets-for-a-repository)

## Verification evidence

- 85 offline policy/CLI tests pass; branch + statement coverage 99.39%.
- Strict mypy, Ruff, Black and shell syntax checks pass.
- Read-only plan after the initial environment creation contains exactly two
  environment PUTs adding signing reviewers, with no ref or variable changes.
- Live OIDC metadata: `use_default=true`, `use_immutable_subject=false`,
  `sub_claim_prefix=repo:Yapio-Ltd/mokaid`. Repository creation was 2026-07-04,
  before GitHub's newer default immutable-subject rollout. The current IAM subject
  matches that observed format; any later opt-in/rename requires revalidation.
  [AWS/GitHub OIDC configuration](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- Zizmor 1.30.1, offline auditor mode on the two workflows: four informational,
  four low and one low-confidence high cache warning. The high warning suggests
  `package-manager-cache`, but the exact pinned setup-node v4 manifest has no such
  input and uses opt-in `cache`; it is not accepted as a confirmed vulnerability.
  Do not add an unsupported input merely to suppress a scanner warning.
  [Pinned official action manifest](https://github.com/actions/setup-node/blob/49933ea5288caeca8642d1e84afbd3f7d6820020/action.yml)
- A narrow pattern check for common literal access keys, private-key headers,
  GitHub tokens and JWTs found no matches in the two workflows, desired policy,
  reconciler and desktop IAM module. This was not a full historical secret scan.

No workflow, IAM role or repository ruleset was changed by this review. Operator
apply/read-back, real signed releases, clean-machine install/update and hardware
acceptance remain distinct checks.
