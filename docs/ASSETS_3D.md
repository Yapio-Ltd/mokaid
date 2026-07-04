# 3D Assets

## Current state: temporary procedural assets

Final GLB assets (office map + avatars) are **not delivered yet**. The scene in `apps/web/src/three/` builds everything procedurally:

- Office: floor, rug, walls, window strip, 10 desks (top/legs/monitor/chair), meeting table, corner plants — simple boxes/cylinders with shared materials.
- Avatars: capsule body + sphere head, tinted per agent (`avatar_config.primary_color`), status ring (torus) colored by agent status.

Everything is resolved through `asset-manifest.ts` where each entry currently points to `procedural:*`. **Swapping in final assets only requires changing manifest URLs** — no scene code changes.

## Delivery requirements for final assets

| Item | Requirement |
|---|---|
| Format | glTF 2.0 binary (`.glb`) |
| Meshes | Draco-compressed, < 50k triangles per asset |
| Textures | KTX2 (BasisU), max 1024×1024, power of two |
| Size budget | ≤ 5 MB per asset, ≤ 25 MB total initial load |
| Avatars | Rigged with the 13 animation states (see below), consistent skeleton |
| Pivot | Centered at floor level, +Y up, meters |

### Required avatar animation states (`AgentVisualState`)

`idle`, `typing`, `working`, `thinking`, `talking`, `reviewing`, `learning`, `waiting`, `requesting_approval`, `blocked`, `celebrating`, `away`, `offline`

The animation state machine already maps agent/task statuses to these states; clips must be named accordingly in the GLB.

## Pipeline

```bash
# 1. Optimize raw exports (Draco + KTX2)
./scripts/optimize-assets.sh assets/raw assets/optimized

# 2. Validate against budgets
./scripts/validate-gltf.sh assets/optimized

# 3. Generate the hashed CDN manifest
npx tsx scripts/generate-asset-manifest.ts assets/optimized https://<cloudfront-domain>

# 4. Upload to the assets bucket (Terraform output: mokaid-assets-3d-<env>-<account>)
aws s3 sync assets/optimized s3://mokaid-assets-3d-.../assets3d/ --cache-control "public,max-age=31536000,immutable"
```

CloudFront serves `/assets3d/*` from the dedicated S3 bucket with immutable caching.
