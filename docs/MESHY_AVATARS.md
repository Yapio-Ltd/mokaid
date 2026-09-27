# Custom Meshy characters

The desktop agent creation/customization dialog offers the existing catalog, a
JPEG/PNG photo, or a description (3–600 characters). Generation continues on the
server when the dialog closes; saved and active jobs can be reopened. Selecting a
completed character supplies its `avatar_asset_id` to the usual agent form.

The retained web form has the same flows. The existing desktop-only production
web routing remains enabled.

## Customer credits and pricing

Creating a custom character costs **1,000 Mokaid credits**, for either a photo or
a description. The desktop and web forms load the server price and available
balance before enabling generation, and show the charge beside the action.
Customer-facing copy uses Mokaid credits without naming the generation provider.
Choosing a photo does not start or charge a generation. Users start generation
explicitly, then select the finished character before adding their teammate.
The dialog footer explains the missing step even when the form is scrolled.

The API requires `expected_credits` matching the current price. Older clients
and stale prices cannot silently incur a new charge. The debit, generation and
queued worker are committed together; insufficient funds reject the request.
The ledger links each debit to its generation. Polls and worker retries do not
charge again. Failed generations refund once; existing characters can be reused
without another charge. Jobs already created before billing was introduced are
not charged retroactively and cannot receive an unearned refund.

Pricing rationale checked 2026-09-27:

- The pinned Meshy-6 pipeline uses 20 provider credits for geometry, 10 for
  texturing and 5 for rigging: 35 provider credits per successful character.
  Image generation with texture also totals 35 including rigging.
- [API pricing](https://docs.meshy.ai/en/api/pricing) documents these operation
  costs. The [API page](https://www.meshy.ai/api) says usage credits are included
  with plans. The published [Pro plan](https://help.meshy.ai/en/articles/12062933-which-meshy-plan-is-right-for-you-free-vs-pro-vs-premium-vs-ultra)
  is $20 for 1,000 credits, giving an estimated $0.70 generation cost at full
  utilization. Actual cost depends on purchased credits and the contract.
- Provisioning $1 per successful character allows $0.30 beyond that estimate
  for processing and unsuccessful attempts. Blender adds no per-animation
  provider fees. The dedicated worker has a fixed hosting cost, which must be
  allocated across actual monthly volume before estimating net profit. At the existing conversion of
  10 Mokaid credits per cost-cent this gives the 1,000-credit customer price.
- The lowest effective paid credit value in the current standard Mokaid plans
  is Scale annual: $1,490 / (12 × 20,000 credits). A 1,000-credit charge allocates
  about $6.21 in revenue, or an estimated 83.9% contribution margin against the
  $1 provision. Purchased packs allocate more revenue per credit.

This is a pricing estimate, not an audited net profit: payment fees, taxes,
fixed costs, utilization, refunds and negotiated/unlimited plans affect actual
margin. Recheck the price when changing the provider model, pipeline or Mokaid
plan grants. The 500-credit free monthly grant alone cannot fund a generation.

## API

- `POST /api/avatar-generations`: JSON `{mode: "text", prompt, name?, expected_credits}`
  or multipart `mode=image`, `file` (JPEG/PNG, at most 10 MB), optional `name`,
  and `expected_credits`.
- `GET /api/avatar-generations` and `GET /api/avatar-generations/:id`: authenticated,
  workspace-scoped jobs including status, progress, asset, thumbnail and error.
  The list response also includes `meta.pricing.credits` and
  `meta.credits.{spendable,unlimited}` for the generation quote.
- `POST https://mokaid.com/api/webhooks/meshy`: Meshy task notifications.
- `GET /api/avatar-assets/:id/:token/:filename`: stable, unguessable read URLs for
  `model.glb`, `model.mokaidasset`, `portrait.png`, and `thumbnail.png`.

Generated assets belong to a workspace; other workspaces cannot list or assign
these assets. Creation requires `agents.create`. At most two generations can run
at once per workspace, with ten submissions per rolling day.

## Pipeline and dimensions

Meshy 6 text preview → texturing → automatic rigging, or image → textured model →
rigging. Rigging requests `height_meters: 1.75`, matching the existing characters.
The rigged input passes through `scripts/prepare-custom-avatar.py` in Blender 5.2
before publication. It reuses the catalog's geometric IK authoring to bake all
48 canonical office actions, including desk/sofa seating and transitions,
keyboard work, phone, coffee and foosball. The source geometry and albedo remain
intact; skin weights and nonmetallic/nonemissive materials are normalized.
Grip joints and cup/phone props use the same runtime visibility conventions as
the catalog. Both engines normalize reference height to 1.75 m.

An independent reimport validates the exported GLB: required clips, skinning,
finite transforms, planted feet, chair/sofa contacts, transition/loop endpoints,
walk speed and prop contacts. The native cooker independently checks the 48-clip
contract, pelvis-first palette and office props. Unsupported humanoid rigs or
failed quality checks never become ready; the customer charge is refunded once.
This supports the known standard humanoid rig, not arbitrary creatures or a
promise that every generated surface can deform without any intersection.

A separate 384×384 transparent portrait is framed using vertices weighted to the
head and its descendants, preserving tall hair and headwear. Clients use
`portrait_url`; a whole-body provider thumbnail is only a generation preview.
The GLB, native asset and portrait must all succeed before publication.

Heavy preparation runs outside database transactions with committed recoverable
claims, a 600-second Blender deadline and 120-second conversion deadline. Child
tools receive no API credentials. Immutable revision keys and rotated media URLs
make existing characters repairable without changing their asset ID. The desktop
reloads a changed URL for the same asset and ignores stale download completions.
Repair uses the saved GLB and never starts a paid provider generation or charges
the customer again. See [worker deployment](CUSTOM_AVATAR_WORKER.md).

### Why this approach

The provider's [rigging API](https://docs.meshy.ai/en/api/rigging) creates a
humanoid skeleton and optional basic walking/running clips; it does not supply
our office behavior library. Its [animation API](https://docs.meshy.ai/en/api/animation)
accepts at most ten action IDs per request, with provider costs for each action.
Those generic actions do not establish contact with Mokaid's measured furniture
and props. Reusing our existing authoring library gives matching behavior and
avoids paying for an additional generic animation pack on every character.

Blender's [glTF export documentation](https://docs.blender.org/manual/en/4.0/addons/import_export/scene_gltf2.html)
describes baked skeletal animations; the runtime consumes ordinary glTF clips
and the existing native format. There is no runtime Blender dependency or need
to retarget between incompatible skeletons in each desktop frame.

The actual reported Goku and a separate generated text fixture passed all 48
animations locally on 2026-09-27. Preparation took about 30 seconds each on the
local machine, not a production throughput benchmark. Reproducible client checks and
validation limits are in [the desktop and web validation report](RELEASE_VALIDATION_2026_09_27.md).
Generated models, detailed measurements and visual evidence remain local.

Private source photos are removed from our upload bucket after success or final
failure. Generated outputs are retained in S3 rather than depending on expiring
Meshy output URLs. Processing resumes with Oban; polls continue every 15 seconds
if webhooks are delayed. A committed submission claim prevents ambiguous paid
POSTs from being automatically repeated after a worker interruption.

## Secrets and deployment

Secrets Manager, `il-central-1`, account `660601648321`:

- `mokaid-prod/meshy_api_key-20260925082706211700000003`
- `mokaid-prod/meshy_webhook_secret-20260925082706211700000001`

ECS injects them as `MESHY_API_KEY` and `MESHY_WEBHOOK_SECRET`. Neither secret value
belongs in source, Terraform variables/state, client bundles or test fixtures.
The production workflow uses GitHub variables containing only their AWS ARNs.
`S3_BUCKET_ASSETS_3D` points to `mokaid-assets-3d-prod-660601648321`; IAM permits
GetObject/PutObject only under `assets3d/generated-characters/*`.

The multiarchitecture release image packages Node and the native asset cooker.
Its x64 variant also packages a checksummed Blender 5.2 runtime for a dedicated
worker with 4 GiB RAM. The ARM64 API does not run avatar jobs. Paid generation is
explicitly gated until that worker is enabled. Local end-to-end generation also
needs Blender/preparer/cooker paths and an S3 bucket; see the worker deployment
document for environment variables and rollout checks.

Meshy's published webhook reference does not specify a signing algorithm. Until
that protocol is verified against a real delivery, the configured secret is
stored but notifications are treated strictly as untrusted wake-up hints: only
known task IDs enqueue a deduplicated authenticated Meshy API fetch. Status and
asset URLs from the webhook are never accepted as authoritative. This avoids
inventing an incompatible signature scheme. Polling works independently.

## Verification

The implementation has focused API/storage, UI and native tests. Two real Meshy
runs on 2026-09-25 succeeded (one description, one repository demo portrait),
including texturing, rigging, GLB download and native conversion. Both generated
native assets were loaded by the actual Office engine and measured at 1.75 m.
No user agent or production workspace was created by these checks.

- [Text to 3D](https://docs.meshy.ai/en/api/text-to-3d)
- [Image to 3D](https://docs.meshy.ai/en/api/image-to-3d)
- [Rigging](https://docs.meshy.ai/en/api/rigging)
- [Webhooks](https://docs.meshy.ai/en/api/webhooks)
- [Meshy webhook and polling guidance](https://help.meshy.ai/en/articles/16102100-meshy-api-webhooks-vs-polling-when-results-are-ready)
