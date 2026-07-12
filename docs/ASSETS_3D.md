# 3D Assets

## Current state

- **Characters**: `avatar_male`, `avatar_female`, `avatar_finance`, `avatar_corporate` GLBs with 14 `AgentVisualState` clips.
  - Female (stylish): Fiverr walking + procedural bake (Mixamo biped).
  - Female finance: Meshy biped clips mapped to AgentVisualState (`scripts/bake-avatar-finance.py`).
  - Corporate: Meshy walking + procedural bake (`scripts/bake-avatar-female.py`).
  - Served from `/assets3d/avatar_*.<hash>.glb` (also on S3 `mokaid-assets-3d-*`).
- **Catalog**: Postgres table `asset_3d` — API `GET /api/assets-3d`. Agents reference via `avatar_asset_id`.
- **Office furniture**: still procedural via `asset-manifest.ts` until environment GLBs ship.

## Delivery requirements for final assets

| Item | Requirement |
|---|---|
| Format | glTF 2.0 binary (`.glb`) |
| Meshes | Draco-compressed, < 50k triangles per asset |
| Textures | KTX2 (BasisU), max 1024×1024, power of two |
| Size budget | ≤ 5 MB per asset, ≤ 25 MB total initial load |
| Avatars | Rigged with the 14 animation states (see below), consistent skeleton |
| Pivot | Centered at floor level, +Y up, meters |

### Required avatar animation states (`AgentVisualState`)

`idle`, `walking`, `typing`, `working`, `thinking`, `talking`, `waiting`, `requesting_approval`, `blocked`, `celebrating`, `away`, `offline`, `reviewing`, `learning`

Bake procedural clips onto a rigged mesh:

```bash
python3 scripts/bake-avatar-animations.py assets/raw/avatar_male.glb
```

## Pipeline

```bash
# 1. Bake clips (if the source GLB has no animations)
python3 scripts/bake-avatar-animations.py assets/raw/avatar_male.glb

# 2. Optimize raw exports (Draco + KTX2)
./scripts/optimize-assets.sh assets/raw assets/optimized

# 3. Validate against budgets
./scripts/validate-gltf.sh assets/optimized

# 4. Hash + copy into the web public folder (and optionally generate manifest)
HASH=$(shasum -a 256 assets/optimized/avatar_male.glb | cut -c1-12)
cp assets/optimized/avatar_male.glb "apps/web/public/assets3d/avatar_male.${HASH}.glb"

# 5. Upload to the assets bucket (Terraform output: mokaid-assets-3d-<env>-<account>)
aws s3 sync assets/optimized s3://mokaid-assets-3d-.../assets3d/ --cache-control "public,max-age=31536000,immutable" --exclude "*" --include "*.glb"

# 6. Upsert catalog metadata
cd apps/api && mix run priv/repo/seeds.exs   # calls Assets3d.seed_catalog/0
```

CloudFront serves `/assets3d/*` when enabled; until then the SPA serves the same path from `apps/web/public/assets3d/`.
