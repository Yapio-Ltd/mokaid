# 3D Assets

## Current state

- **Characters**: `avatar_male`, `avatar_design`, `avatar_finance`, `avatar_corporate`, `avatar_legal`, `avatar_research` GLBs with 14 `AgentVisualState` clips (+ POI).
  - Design (ex-female/stylish): Fiverr walking + procedural bake (Mixamo biped).
  - Female finance: Meshy biped clips mapped to AgentVisualState (`scripts/bake-avatar-finance.py`).
  - Corporate: Meshy walking + procedural bake (`scripts/bake-avatar-female.py`).
  - Legal / lawyer: Meshy walking + procedural bake (`scripts/bake-avatar-female.py` on `assets/raw/legal/`).
  - Research / chercheur: Meshy walk/talk/run overlays (`scripts/bake-avatar-research.py` on `assets/raw/research/`).
  - Served from `/assets3d/avatar_*.<hash>.glb` (also on S3 `mokaid-assets-3d-*`).
- **Catalog**: Postgres table `asset_3d` — API `GET /api/assets-3d`. Agents reference via `avatar_asset_id`.
- **Office environment**: `office.<hash>.glb` (textures max 2048) + `office.mobile.<hash>.glb` (textures max 1024) in `apps/web/public/assets3d/` and S3 `mokaid-assets-3d-*/assets3d/`. Resolved by device profile (`office-asset.ts`).
  - Office meshes use **float32** vertex attributes (no `KHR_mesh_quantization`). Quantized SHORT positions explode under Chrome Windows / ANGLE.
  - `EXT_mesh_gpu_instancing` is expanded to discrete nodes during optimize (`scripts/expand-office-instances.mjs`) for the same ANGLE safety.

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
# 1a. Bake clips (if the source GLB has no animations)
python3 scripts/bake-avatar-animations.py assets/raw/avatar_male.glb

# 1b. Legal / lawyer (Meshy character + walking → procedural AgentVisualState + POI)
python3 scripts/bake-avatar-female.py \
  assets/raw/legal/Meshy_AI_Create_a_beautiful_lo_biped_Character_output.glb \
  assets/raw/legal/Meshy_AI_Create_a_beautiful_lo_biped_Animation_Walking_withSkin.glb \
  -o assets/raw/avatar_legal.glb
python3 scripts/bake-poi-clips.py assets/raw/avatar_legal.glb -o assets/raw/avatar_legal.glb

# 1c. Research / chercheur (Meshy withSkin pack → walk/talk/run + procedural + POI)
python3 scripts/bake-avatar-research.py assets/raw/research -o assets/raw/avatar_research.glb
python3 scripts/bake-poi-clips.py assets/raw/avatar_research.glb -o assets/raw/avatar_research.glb

# 2. Optimize raw exports (avatars Draco+WebP; office resize 2048 + 1024 mobile,
#    then dequantize + expand GPU instances — never re-quantize office)
./scripts/optimize-assets.sh assets/raw assets/optimized

# 3. Validate against budgets (+ reject KHR_mesh_quantization on office)
./scripts/validate-gltf.sh assets/optimized

# 4. Hash + copy into the web public folder (and optionally generate manifest)
HASH=$(shasum -a 256 assets/optimized/avatar_male.glb | cut -c1-12)
cp assets/optimized/avatar_male.glb "apps/web/public/assets3d/avatar_male.${HASH}.glb"
OHASH=$(shasum -a 256 assets/optimized/office.glb | cut -c1-12)
MHASH=$(shasum -a 256 assets/optimized/office.mobile.glb | cut -c1-12)
cp assets/optimized/office.glb "apps/web/public/assets3d/office.${OHASH}.glb"
cp assets/optimized/office.mobile.glb "apps/web/public/assets3d/office.mobile.${MHASH}.glb"
# Update OFFICE_ENVIRONMENT_*_CDN_PATH in apps/web/src/three/office-asset.ts

# 5. Upload to the assets bucket (Terraform output: mokaid-assets-3d-<env>-<account>)
aws s3 sync apps/web/public/assets3d/ s3://mokaid-assets-3d-prod-660601648321/assets3d/ \
  --profile mokaid \
  --cache-control "public,max-age=31536000,immutable" \
  --exclude "*" --include "*.glb"

# 6. Upsert catalog metadata
cd apps/api && mix run priv/repo/seeds.exs   # calls Assets3d.seed_catalog/0
```

CloudFront serves `/assets3d/*` when enabled; until then the SPA serves the same path from `apps/web/public/assets3d/`.
