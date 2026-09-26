# Custom Meshy characters

The desktop agent creation/customization dialog offers the existing catalog, a
JPEG/PNG photo, or a description (3–600 characters). Generation continues on the
server when the dialog closes; saved and active jobs can be reopened. Selecting a
completed character supplies its `avatar_asset_id` to the usual agent form.

The retained web form has the same flows. The existing desktop-only production
web routing remains enabled.

## API

- `POST /api/avatar-generations`: JSON `{mode: "text", prompt, name?}` or multipart
  `mode=image`, `file` (JPEG/PNG, at most 10 MB), optional `name`.
- `GET /api/avatar-generations` and `GET /api/avatar-generations/:id`: authenticated,
  workspace-scoped jobs including status, progress, asset, thumbnail and error.
- `POST https://mokaid.com/api/webhooks/meshy`: Meshy task notifications.
- `GET /api/avatar-assets/:id/:token/:filename`: stable, unguessable read URLs for
  `model.glb`, `model.mokaidasset`, and `thumbnail.png`.

Generated assets belong to a workspace; other workspaces cannot list or assign
these assets. Creation requires `agents.create`. At most two generations can run
at once per workspace, with ten submissions per rolling day.

## Pipeline and dimensions

Meshy 6 text preview → texturing → automatic rigging, or image → textured model →
rigging. Rigging requests `height_meters: 1.75`, matching the existing characters.
The walking GLB is copied to our S3 bucket and prepared for both renderers. The
native cooker uses the same glTF/Draco/texture libraries as the shipped desktop
catalog, emits format 4, and adds a stationary idle pose. Both engines normalize
reference height to 1.75 m. Native characters use their walking clip while moving
and stay grounded for activities without a matching animation. Meshy characters
do not inherit the bespoke seated/coffee/phone animation library of the catalog.

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

The API Docker image packages Node plus the isolated native asset cooker and sets
`MESHY_NATIVE_COOKER`. Production generation fails explicitly if conversion is
unavailable. Local end-to-end generation also needs this env var and an S3 bucket.

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
