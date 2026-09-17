# Native rendering implementation and validation

The engine consumes the shipped, hash-verified avatar revisions from the backend
catalog and the Blender-authored desktop office pinned by
`assets/office-desktop.json`; the scene is not a procedural replacement.
Unversioned authoring intermediates are not used by default. Run
`npm ci --ignore-scripts` and `npm test` in `tools/asset-cooker`, then
`node cook.mjs <output-directory>`. This emits nine `.mokaidasset` files,
`office.mokaidnav` and a SHA-256 manifest. The default output is `build/assets`.
The cooker expands glTF instance transforms, decodes Draco/quantized accessors,
exports skinning/animation and head-position tracks, generates color/data
mipchains, and combines the web navigation source with the desktop manifest's
reviewed obstacle, activity-socket, chair and floor-height overrides. The current
pack contains the office and eight avatar catalog entries (seven distinct rigs;
`avatar_female` aliases `avatar_design`), with 48 clips per avatar entry.

## Office activities

Working agents alternate authored typing, thinking and phone pickup/call/putdown
clips with individual timing. Free agents can prepare and carry coffee, meet a
colleague, sit and talk on the sofa, play foosball in pairs, and return to their
desks. Paired conversations coordinate greetings, laughter and drinking while
keeping separate motion phases. These are local ambient animations; their phone
calls and conversations do not represent external calls or API actions.

The nine physical chairs move with desk departure and return. Navigation pack
`MOKANAV3` binds each chair node to its measured travel and retains the raised
meeting-room floor and seat height. Activity sockets are reserved per agent;
removal and interrupted activities release claims and restore seat ownership.
Swept-disc collision checks cover moving actors and retracted chairs. Route
requests retain queue priority, can ask a blocker to move aside, and retry or
return to a desk when an activity cannot be reached.

The Qt overlay projects cooked head tracks through the same camera as the 3D
view. Stable agent identities keep labels alive as names, levels and activities
change. Placement searches above and below a head, with a viewport-grid fallback
for crowded edges; labels remain in logical UI pixels at every render quality.

## Desktop displays and desk props

`scripts/blender-office-screens.py` runs after `blender-office-desktop.py` and
reassigns only the existing display faces: seven monitors and two laptops. Their
upright UVs and explicit `Desktop screen N` materials avoid interpreting an
entire atlas as a screen. Geometry, furniture placement and navigation remain
unchanged. The script records its input GLB hash and preserves the current
navigation overrides when updating `assets/office-desktop.json`.

Cooked asset v4 appends one `uint32 surfaceKind` after each material's
`alphaCutoff`: 0 is PBR, 1 is an ambient display, 2 is phone geometry, and 3 is
the phone dock. The loader also accepts v3 and defaults its materials to PBR.
`Instance.surfaceMask` selects material kinds without cloning scenes or textures.
The dock stays on the desk; the phone stays there outside the three call clips
and is shown on the avatar during pickup, calling and putdown. Static desk props
reuse the rig's `typing` pose at time zero even while their agent is elsewhere.

Both native backends use `shaders/screen_content.h` for the same code editor,
analytics and browser layouts. Their slow scroll, graph traces and cursor use
`Frame.sceneSeconds`, so scene pause also stops displays. Content is decorative
and local; it does not claim to show tasks or API activity. Nine additional draw
calls reuse the original 22 display triangles and add no screen textures. Only
these explicit surfaces take the display shader path; phone materials retain PBR.

The Metal smoke fixture supports `MOKAID_SCREEN_TIME=8` to compare two display
times without advancing actors. It reports the last six frames' CPU encode and
GPU durations, and validates actor count independently of static prop instances.

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

The final native CTest suite passed 23 tests. Engine and bridge coverage includes
transforms, near/far clip conventions, quaternion interpolation, parent animation,
fallback clips, skin palettes, real cooked assets, nine seat fixtures, navigation,
traffic and activity transitions, plus label projection, stable identity and
crowding at desktop/chat widths and viewport edges.

The Metal Objective-C++ renderer and offline Metal 3 shaders compile. Final
offscreen captures of nine real avatars passed Metal API Validation on an Apple
M4 Pro in a Debug build. All three cases rendered 162 draws and 652,525 triangles:

| Case | Final target (pixels) | Simulation | CPU encode mean | GPU mean |
| --- | --- | --- | --- | --- |
| Desk | 1807 × 835 | 11 s, working | 3.238 ms | 1.952 ms |
| Chat width | 1110 × 835 | 14.2 s, working | 2.920 ms | 2.082 ms |
| Social activities | 1807 × 835 | 90 s, idle | 3.434 ms | 2.210 ms |

Evidence is recorded in
[`native-final-render-validation.json`](../../../artifacts/office-life/native-final-render-validation.json),
for cooked manifest SHA-256
`c3104f113ff3e616da56f48db4ac463353965286edabb145802adc7edfbdee6b`.
The means cover the last six submitted frames, including the fixture's changing
target sizes; they are not a sustained fixed-resolution or full-app FPS result.
PNG readback exists only in `tests/metal_smoke.mm`, never in the presentation
path. The target Mac M1 benchmark remains outstanding.

All six HLSL entry points also compile with DXC's strict warnings-as-errors
settings. The Windows C++ renderer still requires a Windows SDK build and real
D3D11/D3D12 interop validation. Neither shader compilation nor these GPU captures
establishes a 60-FPS guarantee.

The smoke program additionally passes Metal API Validation with 12 unretained
command buffers, odd-size target changes while older frames are in flight, and
renderer destruction before those commands complete. Build the explicit
`mokaid_metal_smoke` target, then run on a real Mac GPU:

```sh
MTL_DEBUG_LAYER=1 build/macos-debug/renderer/mokaid_metal_smoke build/assets build/macos-debug/renderer/shaders /tmp/mokaid-office.png 9
```

Optional width, height, simulated seconds and `idle`/`working` actor status
provide reproducible activity captures. For example, the nine desk fixtures at
11 seconds show both typing styles and ongoing phone calls:

```sh
MTL_DEBUG_LAYER=1 build/macos-debug/renderer/mokaid_metal_smoke build/assets build/macos-debug/renderer/shaders /tmp/mokaid-desk-life.png 9 1063 491 11 working
```

The official Qt module metadata is generated into
`build/<preset>/qml/Mokaid/Native/bridge.qmltypes`. Link `mokaid_viewport` and call
`registerViewportTypes()` once at application startup to retain that generated
registrar; the function does not duplicate manual type registration. QML tools
must include the build's `qml` import directory.

## Remaining renderer and platform limitations

- Lighting uses GGX metallic/roughness textures and 16 lights generated from the
  Blender-derived web manifest (including warm desk lamps and colored overhead
  panels). Two gentle directional fills preserve detail. HDR color and emission
  use separate RGBA16F targets; a half-resolution separable bloom affects actual
  emitters only. ACES filmic display mapping and sRGB encoding happen once, after
  compositing. The cooker filters portrait emission and keeps screen pixels lit.
  Soft analytic body contact darkening anchors avatars; full geometry shadow
  maps and environmental occlusion remain to be implemented.
- Color textures use offline RGBA8 mipchains, not ASTC/BC compressed GPU formats.
  Geometry uses indexed buffers; shared-mesh instancing, LOD and a render graph
  are not implemented yet.
- Animation interpolates authored linear/STEP tracks and GPU skins 128 joints;
  cubic tracks fail cooking. Local TRS crossfades use the web's 0.28-second
  smoothstep, preserve multi-clip interruptions and do not restart an idle clip
  when two missing states resolve to it. Morph animation is not implemented.
  The walking phase follows actual distance, including stops for other agents,
  using the Blender gait's 1 m/s reference at 1.75 m character height. Avatar meter
  scale is calibrated from deformed reference bounds; desk and sofa placement use
  cooked sitting-pelvis measurements and per-socket heights. The current catalog
  supplies 48 clips per entry, including chair motion, distinct walking/typing
  styles, phone handling and standing/seated coffee interactions. Older assets
  retain animation fallbacks. The current choreography is authored for this room;
  it does not provide general-purpose full-body IK or cloth simulation.
- Navigation uses the existing obstacle/anchor data through an occupancy grid,
  not Recast/Detour. Route reservations, swept collision guards, pull-aside
  recovery, paired activity claims and return-to-desk are implemented. Coverage
  concerns this authored nine-desk room; it does not establish arbitrary-crowd
  throughput or compatibility with an unreviewed furniture layout.
- Quality scales the 3D render resolution while Qt UI remains at native pixel
  density. GPU-timing adaptive quality, loss/recreation stress tests, and long
  session budgets remain release gates.

The camera fits the actual room silhouette when the viewport changes, including
the narrow view beside chat. The office header and agent dock reserve their own
space instead of covering the desks. Metal intermediate resources share the same
completion lease as geometry; Direct3D intermediates belong to each frame slot.
Windows packages require all six compiled DXIL shader entry points.

Do not market this baseline as full parity or publish a release until the above
gates and platform UI integration are complete.
