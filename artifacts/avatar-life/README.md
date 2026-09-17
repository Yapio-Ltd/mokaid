# Avatar life — Blender sources and validation

Seven editable Blender sources, each containing 48 baked clips at 60 fps. The preceding 28-clip sources remain in `../avatar-quality`.

## Changes

- Seven distinct walk cadences, torso sway and arm swing; brisk, relaxed and careful coffee variants.
- Focused/relaxed typing, phone pickup/call/putdown, greetings, standing conversation and laughter.
- Seated coffee, sipping, laughter and conversation toward either sofa neighbour, with cup-preserving seat transitions.
- Rigid skinned ceramic cup, phone and desk dock; deforming finger grips on all seven rigs.
- Legal source repair: remove imported hand weights from robe/shoes, keep cuffs on forearms, separate welded hand/sleeve/robe surfaces and close each patch independently; repair residual upper-robe arm influences, blend cuff skinning and reconstruct the flank surfaces with the original cloth atlas. See [the dense regression report](legal-regression/README.md).

## Runtime contract

- Forward: glTF +Z (Blender −Y). Native reflects Z; use the established yaw conversion.
- Reference gait speeds: walking 1 m/s; walking_coffee 1 m/s; walking_brisk 1.35 m/s; walking_relaxed 0.7 m/s. Advance animation from travelled distance.
- Existing chair pullback/pushin remain 0.5 m/s, 1.3 s/cycle. Chair seat is 0.51 m, sofa seat 0.70 m at normalized avatar height 1.75 m.
- Sofa left conversation looks toward glTF/native +X; right looks toward −X.
- Phone uses the anatomical LeftHand (+X side): desk centre (+0.30, +0.40 forward, 0.783 height) metres; dock top 0.778 and bottom 0.762.
- Phone material names: `Desktop phone`, `Desktop phone screen`, `Desktop phone dock`. The runtime can retain a filtered typing(0) prop instance on vacant desks.
- Cup pickup/putdown uses measured machine tray: (−0.20, +0.45 forward, 0.702913 surface height) from coffee POI (native −1.79,+5.23). Cup centre height is 0.764913.
- All new clip durations and one-shot flags are authoritative in `report.json`.

## Gaits and deliverables

| Avatar | Character | Normal cycle | Brisk cycle | Relaxed cycle | Coffee cycle | Source |
|---|---|---:|---:|---:|---:|---|
| avatar_male | purposeful | 0.900s | 0.700s | 1.100s | 0.800s | [avatar_male.blend](avatar_male.blend) |
| avatar_design | light and quick | 0.833s | 0.650s | 1.017s | 0.733s | [avatar_design.blend](avatar_design.blend) |
| avatar_finance | measured | 0.883s | 0.683s | 1.067s | 0.767s | [avatar_finance.blend](avatar_finance.blend) |
| avatar_corporate | deliberate | 0.967s | 0.750s | 1.167s | 0.850s | [avatar_corporate.blend](avatar_corporate.blend) |
| avatar_legal | smooth | 0.933s | 0.733s | 1.150s | 0.833s | [avatar_legal.blend](avatar_legal.blend) |
| avatar_research | nimble | 0.600s | 0.467s | 0.733s | 0.533s | [avatar_research.blend](avatar_research.blend) |
| avatar_developer | loose | 0.917s | 0.717s | 1.117s | 0.817s | [avatar_developer.blend](avatar_developer.blend) |

## Evidence and limits

- `report.json`: export hashes, original source, authored durations, gait parameters, material/rig metadata and measured reach calibration.
- `source-validation.json`: all seven `.blend` files reopened successfully with 48 local, retained actions; source file hashes.
- `validation.json`: independent GLB reimport, exact clip set, loop/transition endpoints, skin weights, material policy, normalized idle bounds, planted soles, walking/chair speed, cup/phone sockets and Legal mesh stretch guard.
- `legal-regression/`: dense 48-clip / 20-crossfade audit, isolated robe dependency test and before/after close-ups.
- `surface-contacts.json`: actual deformed hand vertices against cup handle and interior on six representative poses for each exported GLB.
- `avatar_*-contact-sheet.png`: full-body Blender poses. Male/Design `*-contact-closeups.png` show carry, pickup, putdown, phone pickup and phone at ear.
- Fingers on the six original Meshy rigs use a smooth collective two-joint curl plus separate thumb. They are not individually remodelled fingers.
- Contact tests sample representative poses and verify skin deformation; they are not a complete continuous collision simulation. The initial generated Legal mesh contained welded clothing/hand surfaces and required local topology repair.

## Reproduce

```sh
blender --background --python-exit-code 1 --python scripts/blender-avatar-life.py -- --preview
blender --background --python-exit-code 1 --python scripts/validate-avatar-life.py -- artifacts/avatar-life
blender --background --python-exit-code 1 --python scripts/blender-avatar-life-contacts.py -- artifacts/avatar-life
blender --background --python-exit-code 1 --python scripts/blender-avatar-life-closeups.py -- artifacts/avatar-life
python3 scripts/promote-avatar-quality.py artifacts/avatar-life --artifacts artifacts/avatar-life
```

Promotion verifies matching hashes and clip counts, updates shared web/API paths and copies the content-addressed GLBs. Desktop cooking is a separate integration step.

## Final measurements

All seven exported GLBs pass all 48 clip checks. Normalization uses the actual deformed idle bounds, matching native runtime placement.

| Check | Maximum over seven avatars |
|---|---:|
| Standing/seated foot drift | 0.969 mm |
| Root-compensated transition foot drift | 0.096 mm |
| Stance speed error | 0.0242 m/s |
| Desk sole offset | 1.578 mm |
| Sofa sole offset | 1.071 mm |
| Nearest hand/handle vertex gap, 42 samples | 3.430 mm |
| Hand vertices inside cup interior | 0 |
| Legal complete robe upper-limb weight | 0 |
| Legal max sampled edge stretch ratio, 9,597 poses | 7.968× (previous delivered export: 10.213×) |

## Promoted hashes

| Avatar | Content hash prefix |
|---|---|
| avatar_male | `21ca01757e1a` |
| avatar_design | `1c0dba698d81` |
| avatar_finance | `1db634ff8a82` |
| avatar_corporate | `b2951a24cd02` |
| avatar_legal | `859687268a64` |
| avatar_research | `7c86fc428e9f` |
| avatar_developer | `867211fc6b99` |
