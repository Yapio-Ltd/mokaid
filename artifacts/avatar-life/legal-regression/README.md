# Legal robe regression — 16 September 2026

## Delivered correction

- Previous catalogued GLB: `ecc4899f62c69de9ccf72a32349a74c3b116c65a64c9325daf3d60cf3ec02e1b`.
- Corrected GLB: `859687268a642c7644714cee5ebd5e9f72b6a4835c62140122f3f965f3364198`.
- Editable source: [../avatar_legal.blend](../avatar_legal.blend), reopened with all 48 retained local actions.
- The other six avatars are unchanged. No runtime or asset-cooker change is included here.

The supplied screenshot could not establish the exact runtime animation phase or pack that produced its large cloth triangle. We therefore reimported the actual previously catalogued GLB and found real remaining defects: arm weights on upper central robe vertices and a hard hand/forearm weight seam around the cuffs. The old lower-skirt-only guard did not cover the upper robe.

The repair binds the central robe and side panels to the torso/legs, softens cuff weights, removes residual welded slivers, and reconstructs both side openings with 278 local triangles. Forty-nine irregular body caps were replaced; 54 cuff cap faces now sample the original cloth atlas instead of a visibly lighter constant material. New side panels have no arm influence. The original atlas elsewhere is preserved.

## Same regression on old and new exports

Both files were independently reimported into Blender and sampled at 60 fps: all 48 clips plus 20 transition pairs, three source phases and 21 blend weights each, totalling 9,597 poses. The anatomical robe mask covers the central torso/skirt and lower hem. A separate isolation test freezes the body and rotates the upper-limb joints; it does not depend on edge-length thresholds.

| Check | Previous ecc489 | Corrected 859687 |
|---|---:|---:|
| Maximum upper-limb weight in robe mask | 0.961755 | 0 |
| Maximum robe displacement with only arms moved | 264.270 mm | 0 mm |
| Maximum sampled edge stretch | 10.213× | 7.968× |
| Maximum crossfade edge stretch | 7.970× | 7.613× |
| Clips with pathological edges | 7 | 0 |
| Crossfades with pathological edges | 0 | 0 |
| Retained local actions | 48 | 48 |

A pathological edge means a source edge longer than 2 mm that stretches more than 8× and grows more than 25 mm. The absolute ratio alone is not a claim of physical cloth simulation. Stylized articulation still deforms small edges; this test targets the demonstrated welded-surface failure.

The final regular validator also passes: 0.097 mm standing/seated foot drift, 0.060 mm root-compensated transition drift, 0.0041 m/s walk stance error. Legal's hand/handle vertex gap is 1.055 mm, with no sampled hand vertex inside the cup interior. The 48 animation sampler buffers and their bone targets are identical to the previous GLB, including all prop transforms.

## Evidence

- [audit.json](audit.json): final dense audit, exact GLB hash and PASS.
- [before-full/audit.json](before-full/audit.json): same dense audit on the previous delivered GLB; expected FAIL.
- [animation-integrity.json](animation-integrity.json): unchanged animation buffers and targets.
- [flank-before.png](flank-before.png) / [flank-after.png](flank-after.png): identical camera and coffee pose; the before image is the intermediate weight repair before the final surface reconstruction.
- [before-full/coffee-and-transitions.png](before-full/coffee-and-transitions.png) / [coffee-and-transitions.png](coffee-and-transitions.png): old and new coffee, phone and sofa poses.
- [../validation.json](../validation.json), [../surface-contacts.json](../surface-contacts.json), [../source-validation.json](../source-validation.json).

## Reproduce

```sh
blender --background --python-exit-code 1 --python scripts/blender-avatar-life.py -- --only avatar_legal --preview
blender --background --python-exit-code 1 --python scripts/validate-avatar-life.py -- artifacts/avatar-life avatar_legal
blender --background --python-exit-code 1 --python scripts/blender-legal-regression.py -- artifacts/avatar-life/avatar_legal.glb artifacts/avatar-life/legal-regression
blender --background --python-exit-code 1 --python scripts/blender-avatar-life-contacts.py -- artifacts/avatar-life
blender --background --python-exit-code 1 --python scripts/blender-legal-flank-closeup.py
python3 scripts/promote-avatar-quality.py artifacts/avatar-life --artifacts artifacts/avatar-life --only avatar_legal
```

For an already baked 48-action source, `scripts/blender-avatar-life-finish-legal.py` applies the repair without rebaking actions. Promotion requires a passing dense audit for the exact Legal hash. Cooking the desktop pack remains a separate integration step.
