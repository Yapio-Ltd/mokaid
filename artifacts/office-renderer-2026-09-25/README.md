# Native renderer GPU evidence — 2026-09-25

These are synthetic native-renderer fixtures, not screenshots of a connected workspace. The nine agents come from the existing smoke test. `atlas-lifetime.png` intentionally uses colored tiles to exercise GPU atlas updates; it does not represent task content.

- `before.png`: original renderer before these changes, 1440×960.
- `reflections-glow.png`: updated environment, final wide overview, mirrored floor reflections, two-scale emission glow, environment illumination and directional antialiasing, 1440×960. Screens without a supplied atlas remain dark.
- `atlas-lifetime.png`: atlas replacement/reuse/removal fixture; captured before the final floor-overlay clipping correction, so it is evidence of atlas behavior rather than final floor appearance.

The final reflection shader mirrors at the authored slab's Y=-0.012 plane. The pass clips Y<0.003 because the room-wide emissive trace sheet sits at Y=0.000405 and otherwise masks reflected furniture. Neighboring office geometry is excluded from the reflection pass.

Validation: Metal shader compilation and Objective-C++ renderer/smoke syntax checks passed. GPU smoke on Apple M4 Pro with Metal API validation passed 12 unretained command buffers, in-flight odd-size resizes and renderer destruction. The atlas fixture additionally passed replacement, reuse and removal during those frames. At 1440×960 the atlas fixture reported 4.06ms GPU mean for the last six frames; the final corrected reflection run reported 6.49ms during concurrent local verification. These short captures are not a sustained performance benchmark. Direct3D12/HLSL source parity was reviewed, but no Windows GPU or DXC compiler was available on this Mac.

Run the atlas lifetime case after a coordinated build:

```sh
MOKAID_SCREEN_ATLAS_TEST=1 MTL_DEBUG_LAYER=1 apps/desktop/build/macos-debug/renderer/mokaid_metal_smoke apps/desktop/build/assets apps/desktop/build/macos-debug/renderer/shaders /tmp/atlas-lifetime.png 9 1440 960
```
