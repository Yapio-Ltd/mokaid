# Blender avatar activity delivery

Seven editable avatars, 28 clips each (196 exported clips). Blender 5.2.0 LTS.

## Inspection

- [Timing sheet: 35 actual Blender poses](motion-sequences.png)
- [Authoring report](report.json)
- [Independent GLB reimport validation](validation.json)
- [Runtime contracts and reproduction](../../docs/3d-motion-validation.md)

## Sources and exports

| Avatar | Editable source | Contact sheet | Export hash |
| --- | --- | --- | --- |
| avatar_male | [avatar_male.blend](avatar_male.blend) | [Preview](avatar_male-contact-sheet.png) | `e5faef146311` |
| avatar_design | [avatar_design.blend](avatar_design.blend) | [Preview](avatar_design-contact-sheet.png) | `364bc2df755b` |
| avatar_finance | [avatar_finance.blend](avatar_finance.blend) | [Preview](avatar_finance-contact-sheet.png) | `7efcf42ab3c6` |
| avatar_corporate | [avatar_corporate.blend](avatar_corporate.blend) | [Preview](avatar_corporate-contact-sheet.png) | `f45ebfc16417` |
| avatar_legal | [avatar_legal.blend](avatar_legal.blend) | [Preview](avatar_legal-contact-sheet.png) | `1adbeb4fb01e` |
| avatar_research | [avatar_research.blend](avatar_research.blend) | [Preview](avatar_research-contact-sheet.png) | `2c615fb1dbe8` |
| avatar_developer | [avatar_developer.blend](avatar_developer.blend) | [Preview](avatar_developer-contact-sheet.png) | `3b4ee2498fb0` |

## Final measured maxima

| Check | Maximum |
| --- | --- |
| Transition endpoint component difference | 0.000000  |
| Walking stance velocity error | 0.000720 m/s |
| Chair stance velocity error | 0.004532 m/s |
| Transition foot drift after synchronized root movement | 0.095753 mm |
| Cup grip error | 0.001536 mm |
| Carried cup upright error | 0.000000 rad |
| Foosball handle height error | 0.035689 mm |
| Chair/desk sole offset | 1.578467 mm |
| Sofa sole offset | 1.070530 mm |

All loops close exactly. Skin weight sum error is below 0.000017. All 35 materials are nonmetallic and nonemissive. Normalization uses evaluated idle-pose geometry, matching native referenceHeight.

Chair motion requires distance-driven playback at 0.5 m/s and a short seated settling blend before stand-up. The design avatar uses a deeper foosball stance because its original arms are short; bone lengths are preserved. Only the male source has articulated finger joints.
