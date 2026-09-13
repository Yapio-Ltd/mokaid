# Native rendering implementation and validation

The engine consumes the shipped, hash-verified avatar revisions from the backend
catalog and the current web office; the scene is not a procedural replacement.
Unversioned authoring intermediates are not used by default. Run
`npm ci --ignore-scripts` and `npm test` in `tools/asset-cooker`, then
`node cook.mjs <output-directory>`. This emits nine `.mokaidasset` files,
`office.mokaidnav` and a SHA-256 manifest. The default output is `build/assets`.
The cooker expands glTF instance transforms, decodes Draco/quantized accessors,
exports skinning/animation tracks, generates color/data mipchains, and extracts
obstacle geometry and patrol lanes from the web source of truth.

## Boundaries

- `mokaid_engine`: Qt-independent asset validation, column-major RH Y-up math,
  [0,1] projection depth, skeletal animation, fixed-step worker, occupancy-grid
  navigation and immutable scene snapshots. Physical desk indices are stable.
- `mokaid_renderer`: Metal or Direct3D 12. Receives borrowed native handles. It
  never includes Qt, QRhi, Chromium, or private Qt headers.
- `mokaid_viewport`: the only native Qt adapter. `registerViewportTypes()` exposes
  `Mokaid.Native 1.0 / NativeViewport`; error/loading properties must be surfaced
  in the UI. Native Qt API changes require revalidation when Qt is upgraded.

On macOS, draw commands are encoded into Qt's current Metal command buffer before
Qt's render pass. Queue ordering and an explicit completion-handler resource
lease keep shared output and mesh resources alive. Textures never cross the CPU.
On Windows, the engine creates D3D12 on the exact adapter used by Qt's D3D11
device. Three RGBA8 outputs are shared through NT handles. Producer/consumer
fences synchronize both queues, and allocator/upload reuse waits for completed
GPU work. Native texture imports are replaced as the ring advances.

## What has actually been verified

Portable CMake tests validate transforms, near/far clip conventions, quaternion
interpolation, parent animation, fallback clips, skin palettes, nine seat
fixtures, every real cooked scene, and patrol waypoints outside furniture.
The Metal Objective-C++ renderer and offline Metal 3 shaders compile. The
standalone `tests/metal_smoke.mm` verification program has rendered the current
office and nine animated avatar fixtures on an Apple M4 Pro: 101 draws and
645,757 triangles without a Metal command-buffer error. Its PNG readback exists
only in the verification program, never in the presentation path. This is not
the full Qt/Metal/WebEngine integration test or the target Mac M1 benchmark.
Windows source requires a Windows SDK build and real D3D11/D3D12 interop
validation. Neither compilation nor these tests establishes a 60-FPS guarantee.

The smoke program additionally passes Metal API Validation with 12 unretained
command buffers, odd-size target changes while older frames are in flight, and
renderer destruction before those commands complete. Build the explicit
`mokaid_metal_smoke` target, then run on a real Mac GPU:

```sh
MTL_DEBUG_LAYER=1 build/macos-debug/renderer/mokaid_metal_smoke build/assets build/macos-debug/renderer/shaders /tmp/mokaid-office.png 9
```

The official Qt module metadata is generated into
`build/<preset>/qml/Mokaid/Native/bridge.qmltypes`. Link `mokaid_viewport` and call
`registerViewportTypes()` once at application startup to retain that generated
registrar; the function does not duplicate manual type registration. QML tools
must include the build's `qml` import directory.

## Remaining renderer parity work

This is a functional native baseline, not the finished renderer specified by
the product plan. Its current limitations are explicit:

- Lighting uses GGX metallic/roughness textures, two directional lights, neutral
  indirect light and authored emissive textures. The cooker moves the emitter
  allowlist and basic albedo corrections out of the render loop. Full authored
  lighting, pixel-specific atlas corrections, shadows, bloom and ACES have not
  reached web visual parity.
- Color textures use offline RGBA8 mipchains, not ASTC/BC compressed GPU formats.
  Geometry uses indexed buffers; shared-mesh instancing, LOD and a render graph
  are not implemented yet.
- Animation interpolates authored linear/STEP tracks and GPU skins 128 joints;
  cubic tracks fail cooking. Local TRS crossfades use the web's 0.28-second
  smoothstep, preserve multi-clip interruptions and do not restart an idle clip
  when two missing states resolve to it. Morph animation and the full POI/seat
  socket transition choreography still require porting and visual fixtures. Avatar meter scale is
  calibrated from deformed reference bounds, and desk Y uses the web's pelvis
  sitting-height measurement and its fallback for missing sitting clips.
  The current shipped developer GLB has 14 clips and no `sitting`, despite the
  catalog's generic 17-clip declaration; the native fallback remains explicit.
- Navigation uses the existing obstacle/anchor data through an occupancy grid,
  not Recast/Detour. Patrol, basic separation and return-to-desk are implemented;
  full crowd recovery and POI reservations still require parity work.
- Quality scales the 3D render resolution while Qt UI remains at native pixel
  density. GPU-timing adaptive quality, loss/recreation stress tests, and long
  session budgets remain release gates.

Do not market this baseline as full parity or publish a release until the above
gates and platform UI integration are complete.
