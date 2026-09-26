# Smile calibration

The before/after PNGs are diagnostic orthographic, unlit albedo projections of the actual bundled glTF geometry. They isolate the authored facial deformation from lighting, normal repair and texture restoration. They are not screenshots of the native renderer; use the sibling native portrait captures to judge final rendering.

`apps/desktop/tools/asset-cooker/character-expressions.mjs` defines seven manually calibrated families in source skinned bind-world metres, Y up, face toward +Z. Mouth corners, cheek centres, eyes and Legal's inner brows were located against the projected facial features and sampled front-surface depth. Compact smooth deformation fields lift the corners and cheeks, with central lips pinned. Existing tooth smiles on Corporate and Developer receive smaller adjustments. Hair bounds are deliberately not used to locate facial features.

The deformation modifies cloned POSITION accessors only. Original source GLB files and every UV, material, texture, index, joint, skin weight, node transform and animation accessor remain unchanged. All 48 animation clips remain. The cooker then repairs normals to follow the edited geometry. Recoloured aliases share the identical family geometry.

Validation: `node --test character-expressions.test.mjs` passes 14 tests, including every bundled avatar and a nonuniform skin transform / duplicated facial seam fixture.

| Family / aliases | Corrected vertices | Maximum displacement |
| --- | ---: | ---: |
| Male | 324 | 6.888 mm |
| Design / Female | 33 | 1.694 mm |
| Finance / Nyx | 120 | 4.050 mm |
| Corporate / Byte | 337 | 2.442 mm |
| Legal | 112 | 8.297 mm |
| Research | 214 | 6.651 mm |
| Developer / Moss | 694 | 1.823 mm |
