# Office motion changes — 2026-09-06

The existing Babylon office and GLB assets remain the visual source of truth.

Changes:

- Crossfade clips over 280 ms, preserving weights when interrupted; retire outgoing clips.
- Match walk playback speed to navigation speed, including braking and fallback navigation.
- Complete sparse activity tracks with authored rest transforms so retargeted walks cannot leave limb translations behind.
- Recognize prefixed pelvis nodes and evaluate the seated pose before measuring cushion alignment.
- Keep all avatar parts eligible in the frozen active-mesh list, including parts initially outside the camera frustum.
- Keep seated avatars out of Detour when the navigation mesh finishes loading.
- Approach sofa cushions individually and navigate directly to walkable coffee/foosball slots.
- Separate rising from departing a seat; preserve an existing desk pose on task-state changes.
- Replan congestion in place before using the existing last-resort relocation.
- Isolate avatar materials and release cloned materials/skeletons on removal, preserving shared textures.
- Use a more neutral ambient fill and lighter vignette to improve room readability.

Validation commands (from apps/web):

```sh
npm run typecheck
npm run test -- --run src/three
npm run build
# Start npm run dev separately; no API account is required:
node scripts/verify-office-transitions.mjs
```

The browser fixture uses real office/character assets and the real navigation state machine. It advances fixed simulation steps to check simultaneous activities and return to assigned chairs. This is a route/state regression test, not a hardware performance benchmark or a guarantee of zero mesh intersections in every configuration.

Desktop and iPad-size Chromium views were inspected locally using SwiftShader. Native Windows/ANGLE, macOS/Metal, Safari/iPadOS, all catalog avatars, and sustained thermal performance still require real-device validation. Existing device quality profiles and asset texture variants were preserved. No production deployment or GLB re-authoring is included in this change.

## Blender rig and animation re-authoring — 2026-09-15

The seven production catalog avatars were loaded and edited in **Blender 5.2.0 LTS**. The source revisions are pinned in `assets/avatar-authoring-sources.json`; the authoring process does not require downloading assets or contacting a service.

Confirmed source defects:

- Finance had 36 animation sampler input/output length mismatches, preventing a Blender animation import.
- Developer advertised the full catalog but supplied only 14 clips, with no seated, coffee or foosball action.
- Several procedural clips had different first/last poses; many were sparse, allowing transforms from another clip to survive transitions.
- The male eye highlights were weighted to an independent `neutral_bone`, leaving visible floating dots above a lowered/turned head.
- Several source skins contained weights whose sums differed from one.
- The six Meshy material sets defaulted to metallic surfaces, emitted their albedo as light, and used amplified specular color. This caused black sparkling skin/clothes and self-lit white coats in the actual GPU renderers.

Changes authored in Blender:

- Preserve character geometry, bind proportions, bone names and albedo textures. Rebind the misplaced eye highlights to the head; normalize existing skin weights without adding influences.
- Bake 18 named actions per avatar at 30 fps, including a separate `sitting_sofa` action. Complete local translation/rotation/scale tracks make transitions deterministic in both renderers.
- Solve leg and arm poses from measured segment lengths, with soft elbows and forward-facing knees. Measure each hand's actual weighted geometry to orient its fingers and palm correctly despite different source bone rolls.
- Author a 1.1-second in-place walk (0.6 seconds for the short-legged research character) for **1.0 m/s at 1.75 m avatar height**. The grounded foot moves backward at constant speed over 60% of the cycle; the raised foot clears the floor with a smooth arc. Runtimes must advance the clip according to actual travel.
- Calibrate the desk pelvis to **0.51 m** and sofa pelvis to **0.70 m** above the sole after runtime normalization. All desk actions share the same pelvis and foot placement. `sitting_sofa` requires its own runtime pelvis measurement and clip selection.
- Correct all 21 avatar materials in Blender: metallic zero, emission color/strength disconnected and zero, roughness at least 0.65, normal specular IOR level (0.5) and unamplified specular tint. The material-only re-export verifies that animation curve bytes and albedo factors/image bytes remain unchanged.
- Export Draco positions at 16-bit precision and weights at 16-bit precision. Exclude Blender's generated bone display objects by selecting only the character meshes and armature.

Reproduce and validate locally:

```sh
blender --background --python-exit-code 1 --python scripts/blender-avatar-quality.py -- \
  --output /tmp/avatar-quality --preview --save-blend
blender --background --python-exit-code 1 --python scripts/validate-avatar-quality.py -- /tmp/avatar-quality
python3 scripts/promote-avatar-quality.py /tmp/avatar-quality
node apps/desktop/tools/asset-cooker/cook.mjs
```

`validate-avatar-quality.py` reimports the exported files into Blender. It checks the clip set, duration, sampler lengths, quaternion normalization, exact loop endpoints, weight sums/influence counts, ankle stability, constant-speed stance, identical desk pelvis placement, and **evaluated deformed mesh soles after applying the runtime scale and respective desk/sofa socket offset**. It also rejects the old independent eye-highlight weights.

Final validation covered 126 actions and 270,280 skinned vertices. All loop endpoints match exactly; maximum weight-sum error is 0.0000162. Sampled deformed soles land within 1.002 mm of the desk floor and 0.935 mm of the sofa floor after runtime placement. Fractional-frame stance speed differs from the 1.0 m/s target by at most 2.49%; the maximum sampled mesh ground-height variation is 1.688 mm in source units. The male skin palette starts with the pelvis after removing the now-unused neutral joint.

For an existing baked library, `scripts/blender-avatar-materials.py` applies the same material policy without regenerating poses. The validator rejects emissive, metallic, overly smooth or amplified-specular avatar exports.

The editable `.blend` files, rendered contact sheets and measured reports are retained in `artifacts/avatar-quality/`. The API catalog and browser paths reference the new content hashes; the desktop cooker reads that same catalog. Historical GLBs remain available. No asset upload or production deployment is part of this local change.

These checks establish the measured rig, clip and contact properties; they do not claim that every gesture is motion-capture quality or prove absence of every clothing self-intersection from every camera angle. The authored hand poses are reusable office gestures; keyboard, mug and foosball prop contacts still depend on the corresponding runtime socket geometry.

## 2026-09-16 — real activity clips, seat transitions, and held coffee

The editable sources in `artifacts/avatar-quality/*.blend` now contain 28
60 fps actions per avatar. This pass was authored and rendered in Blender 5.2,
starting from the material-corrected sources above. The web and desktop share
these GLBs; the native activity controller drives the new clips.

### Clip and coordinate contract

- Avatar forward is Blender `−Y`, exported glTF `+Z`. The native instance
  reflects Z, so its visible forward is `(-sin(yaw), 0, -cos(yaw))`.
- `walking` and `walking_coffee` are in-place, calibrated to **1 m/s** at a
  **1.75 m** evaluated idle height. Period is **0.9 s**, or **0.6 s** for the
  short-legged research avatar. Stance occupies 60% of each leg cycle; swing
  joins with matching velocity. Arm swing follows the opposite leg's stride.
- `sit_down` lasts **1.1 s**; `stand_up`, `sit_down_sofa`, and
  `stand_up_sofa` last **1 s**. They are not loops. Their endpoints exactly
  match idle/chair/sofa frame zero, including every exported joint TRS.
  Pelvis height moves to **0.51 m** for a chair or **0.70 m** for the sofa.
- Seat transitions keep the asset root XZ fixed. Local feet advance with
  `u²(3−2u)`; the runtime moves the root back by **0.4025 m** (chair) or
  **0.245 m** (sofa) with that same curve. These motions cancel at the feet.
  Standing up reverses the curve.
- `preparing_coffee` is a **4 s one-shot**: one hand places the cup at the
  machine, the other presses its control, then the cup returns to the chest.
  Its final pose exactly matches `carrying_coffee` frame zero.
- `carrying_coffee` (**3 s**), `drinking_coffee` (**3.6 s**), and
  `talking_coffee` (**5 s**) are standing actions. Drinking raises and tilts the
  cup; talking gestures with the free hand. `walking_coffee` keeps the cup
  level while the legs absorb the gait.
- `playing_foosball` (**2 s**) uses asymmetric push/pull strokes and wrist
  rotation. After measuring the transformed table, wrist targets use rod
  height **0.956 m**, forward reach **0.36 m**, and hand spacing **0.38 m**.
  The pelvis advances **0.10 m** while the feet remain planted. Short arms
  use more knee flexion instead of bone stretching; the design avatar needs
  the deepest stance (pelvis lowered about **0.245 m**).

- `chair_pullback` and `chair_pushin` are seated **1.3 s loops**, with two
  small step cycles per leg and reference chair speed **0.5 m/s** (**0.65 m**
  travel per clip). The native controller advances their animation time from
  actual chair distance, including acceleration and braking. Their pelvis
  remains at **0.51 m**. A short seated blend settles the feet before the
  nonloop stand-up transition.

### Cup and rigging

The ceramic cup, rounded handle, inner wall, and coffee surface are a rigidly
skinned mesh bound to `cup_socket`, a child of `hand.r` on the male Rigify
avatar or `RightHand` on the six other rigs. This uses the existing native
skin/TRS pipeline and needs no attachment format. The cup socket has scale 1
for the five coffee clips and positive scale 0.0001 elsewhere, avoiding
singular skin matrices. The hidden cup does not alter evaluated idle bounds.
The male rig's existing finger joints curl around the cup handle and foosball
rods. The six other source rigs have no individual finger joints; their
original finger geometry is retained.

### Reproduction and inspection

```sh
blender --background --python-exit-code 1 \
  --python scripts/blender-avatar-quality.py -- \
  --from-blend artifacts/avatar-quality --output /tmp/avatar-activities \
  --preview --save-blend
blender --background --python-exit-code 1 \
  --python scripts/validate-avatar-quality.py -- /tmp/avatar-activities
python3 scripts/promote-avatar-quality.py /tmp/avatar-activities
node apps/desktop/tools/asset-cooker/cook.mjs
```

The author also supports the pinned original sources by omitting
`--from-blend`. `blender-avatar-rebake-foosball.py` updates only the measured
foosball action in an already baked directory. `blender-avatar-motion-sheet.py`
renders five timing samples of walking, sitting down, preparing coffee,
drinking, foosball, and both chair movements. Per-avatar contact sheets and the timing sheet are
retained with the editable sources.

The validator independently reimports every exported GLB. Its normalization
uses the actual skinned `idle(0)` bounds, matching native `referenceHeight`.
Checks cover all 28 clip names/durations, nonloop endpoint continuity, finite
unit quaternions, skin weights, nonmetallic/nonemissive materials, deformed
soles, stance speed, root-compensated transition appuis, cup visibility/grip/
uprightness, measured foosball handle contacts, and chair push stance velocity. The durable JSON reports
record the final measurements and exact content hashes.

The web clip registry retains all 28 names independently and treats the five
one-shot activity/transition clips as nonloops. The focused animation suite
passes **9 tests**, and the web TypeScript check passes. These compatibility
changes do not alter web circulation.

## Office life expansion — 48 clips

The current catalog now delivers 48 clips for all seven rigs. Editable sources,
content hashes, measurements and Blender contact sheets are indexed in
[`artifacts/avatar-life/README.md`](../artifacts/avatar-life/README.md).
The earlier 28-clip source directory remains as the authoring baseline.

The new author gives each rig a distinct cadence and arm/torso motion, with
brisk (1.35 m/s), relaxed (0.7 m/s), normal and careful coffee (1 m/s) walks.
It adds focused/relaxed typing, skinned desk phone pickup/call/putdown,
greetings, laughter, standing conversation, and coffee-preserving sofa
transitions with left/right neighbour conversation.

All rigs now have useful finger grips. Male retains its articulated fingers;
the six Meshy meshes use two collective curl joints and a separate thumb per
hand. Cup placement is fitted against actual deformed hand geometry. On 42
samples of the independently reimported final GLBs, the maximum nearest
handle-vertex gap is 3.431 mm and no hand vertex enters the cup interior.

The Legal source contained imported hand weights on the lower robe and welded
triangles connecting hands/cuffs to the garment. The new pipeline repairs the
weights, separates and closes the anatomical surfaces, and removes residual
degenerate welded slivers across 40 sampled poses. A new regression guard
checks central robe hand weights (now zero) and actual deformed edge stretch
(maximum 7.714×; the defective source reached roughly 200×).

Across the seven final exports, standing/seated foot drift is under 0.969 mm,
root-compensated seat-transition drift under 0.096 mm, and stance-speed error
under 0.0243 m/s. These tests use native-equivalent deformed idle bounds.
The source scripts and exact command sequence are in the artifact index;
desktop cooking and native interaction tests remain integration checks.


## Legal robe follow-up — 16 September 2026

Legal is now `859687268a642c7644714cee5ebd5e9f72b6a4835c62140122f3f965f3364198`. The previous delivered `ecc489` still had upper-robe arm weights and a hard cuff seam; the narrow lower-skirt test had missed these. Blender repairs now include body-only torso/side bindings and two locally reconstructed cloth panels using the original atlas. The 48 animation buffers and prop targets are unchanged.

The same 9,597-pose audit on both exports covers all 48 clips and 20 crossfades. Before: seven clips had pathological edges, maximum 10.213×; isolated upper-limb motion moved robe vertices up to 264.270 mm. After: no pathological edges, maximum 7.968×; complete robe upper-limb weight and isolated displacement are both zero. Source reopens with 48 local actions, and the standard contact/sole/material validator passes. See `artifacts/avatar-life/legal-regression/README.md` for hashes, sampling limits, JSON results and identical-camera surface close-ups.
