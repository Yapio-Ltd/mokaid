# Custom character preparation — local validation

Two existing generated assets were processed locally using Blender 5.2.0 LTS.
No new generation requests or uploads were made. Input capability URLs are
intentionally absent; source hashes are recorded in each manifest.

| Input | Outputs | Preparation time | Clips | Maximum planted-foot drift | Desk sole offset |
| --- | --- | ---: | ---: | ---: | ---: |
| Actual Goku character from the reported issue | `goku/` | 32.9 s, including contact sheet | 48 | 0.461 mm | 2.114 mm |
| Previously generated text fixture | `text/` | 29.8 s | 48 | 0.675 mm | 5.599 mm |

Each output directory contains the enriched `model.glb`, a transparent 384×384
`portrait.png` framed from evaluated head/hair skin weights, and `manifest.json`.
Goku also has `contact-sheet.png`; its simple desk and seat surfaces are offline
measurement references, not a screenshot of the running office.

The script reuses the catalog's procedural animation authoring and measured IK.
It preserves source vertex positions and albedo, normalizes skin weights and
nonmetallic/nonemissive materials, adds grip joints plus rigid cup/phone props,
then bakes the same 48 named office actions. It independently reimports the
exported GLB through `validate-avatar-life.py` before marking the output ready.
Validation covers actual deformed soles, loop endpoints, transition continuity,
seat contacts, gait velocity, prop visibility, phone/cup contact, and foosball
hand targets. The current implementation accepts the known standard humanoid
skeleton; unsupported or uncalibratable shapes fail before promotion. These
sampled tests do not establish absence of every possible cloth intersection.

Reproduce (supply the local input file):

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background --python-exit-code 1 \
  --python scripts/prepare-custom-avatar.py -- \
  --input /path/to/original.glb --output-dir /tmp/prepared-character --preview

/Applications/Blender.app/Contents/MacOS/Blender --background --python-exit-code 1 \
  --python scripts/test-prepare-custom-avatar.py
```

The six fast boundary tests passed. CPU Cycles renders work without a display;
`MOKAID_PORTRAIT_EEVEE=1` opts into EEVEE for the portrait on a known GPU host.
The preparation scripts require Blender 5.2 or newer and emit a failure manifest
with no reusable model/portrait when any preparation or validation step fails.

## Integrated backend and clients

The Elixir `NativeCooker.prepare/1` path was also exercised with the real Goku
source, including the credential-isolated process runner, Blender and strict
Node conversion. It completed in 34.4 seconds with 48 clips; see
`backend-runner.json`. GLB: 16.7 MB; native asset: 40.8 MB; portrait: 166 KB.

The actual native Metal office fixture loaded both characters at 1.75 m and
rendered Goku seated at a desk. Its overview screenshot is in
`native-captures/meshy-generated-office-overview.png`; fixture agent labels are
synthetic test data. The desktop application and affected tests build.

Focused integration verification: 46 API generation/billing/repair tests, 48 web
creator/portrait tests, TypeScript checking, 43 asset-cooker tests (one existing
skip), six Blender input-boundary tests and three process-runner tests passed.
Native loader/viewport revision regressions and the feature QML suite also
passed. An independent backend review found no actionable issues.

No production deployment, existing live-avatar replacement, paid generation or
new AWS resource creation was performed. Existing avatars can be queued for
repair with `Mokaid.Avatars.RepairWorker.enqueue(generation_id)` after the worker
is deployed; the repair preserves the asset ID and never charges credits.

Deployment preparation also passed five worker-runtime configuration tests,
85 deployment-policy tests (134 subtests), Terraform validation/format checks,
and local AMD64 Docker smoke builds for the pinned Blender preparation stage
and the Node cooker stage. A complete API release image was not built locally.
