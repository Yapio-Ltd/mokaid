# Desktop office: circulation, activities and framing

## Coordinate and motion contracts

The exported characters face glTF `+Z`. The native instance reflects Z to match
the office coordinate system, so an actor at yaw zero faces world `-Z`.
Its world forward is `(-sin(yaw), 0, -cos(yaw))`; walking toward `(dx,dz)`
therefore requires `atan2(-dx,-dz)`. Translating while rotating through a large
heading error produces the apparent backwards walk even with a valid clip.

Walking clips use a reference speed of 1 metre per second at the native
1.75 metre display height. Runtime playback follows actual distance travelled,
so a stopped or yielding actor must not continue to play a walking cycle.
The native standing reference height comes from skinned idle bounds; it must
not be replaced with raw mesh accessor bounds, which differ across these rigs.

The seven Blender sources now contain 28 clips each, including chair pullback
and push-in, one-shot sitting/standing transitions, carrying/drinking coffee and
two-handed foosball. A skinned cup socket follows the hand. Blender reimport
checks cover all 196 clips; measured stance error stays below 0.000720 m/s and
transition foot drift below 0.096 mm under synchronized root movement. See
`artifacts/avatar-quality/README.md` for the sources and measured tolerances.

## Circulation and physical activities

The simulation uses fixed steps and actual distance to time the walking cycle.
Characters first turn toward their next segment, then move forward. A waiting
character switches to a standing pose, keeping the feet still.

The traffic controller reserves crossing corridors in request order. Conflicting
actors wait; an actor occupying the passage can move to a verified side position
and resume its original route after the other passes. Path planning includes
stationary actors and swept movement segments, rather than checking only the
next frame's endpoints.

Desk departure rolls the chair and its seated occupant backward, settles the
pose, then plays the standing transition before entering a walking route.
Returning reverses these phases. Each chair has its own measured travel distance.
The chair root's parent transform is respected when applying translations.
Work arriving during a leisure activity completes the local physical transition
before routing the actor back to its own desk. Replacing or removing an actor
restores its chair and releases its activity reservation.

## Map and framing

The desktop now uses its own Blender-authored room variant, recorded with a
SHA-256 in `assets/office-desktop.json`. The web room remains the source of the
furniture layout. `scripts/blender-office-desktop.py` trims the empty foreground
tip, adds a 19 cm plinth with a bevel and a thin violet perimeter inlay, and
widens the open side aisle by 30 cm. The editable source is
`artifacts/desktop-office-quality/office-desktop.blend`.

The native variant also repairs physical interactions:

- The baby-foot table moves to `(-3.10, -4.67)` and scales uniformly by 1.6.
  Both long sides are accessible, with hands calibrated to its 0.956 m handle
  height. The previous eastern player position collided with a real partition.
- Nine named chair nodes can roll independently. Two were merged with other
  chairs in the source atlas and are now separated, preserving the other chair.
  Measured pullback distances prevent standing up into desk tops.
- The meeting room floor is 0.064917 m high. Chair 5 faces its actual desk, and
  its adjustable cushion is set to 0.51 m above that platform. Actor placement
  accounts for the platform instead of sinking feet into it.

Socket, obstacle and waypoint overrides belong to the native variant's
manifest; they do not move interaction points on the unchanged web room.

The native floor outline includes the widened sloping side and the new plane
`x - z <= 11.2`. Navigation must inset both boundaries by the actor radius;
using only the rectangular room bounds allows people to walk beyond the floor.

The camera smoothly reduces its elevation for wide viewports, retaining the
more overhead angle when chat narrows the office. It fits the actual silhouette
to 97% of the viewport, with 74/100 px top/bottom space reserved by QML.

Measured geometry projection in the 1266 × 768 desktop window:

| Office mode | Previous silhouette | Updated silhouette |
| --- | --- | --- |
| Full office | 843 × 441 px | 1023 × 476 px |
| Chat open | 614 × 319 px | 633 × 324 px |

These are projections of the final widened room, not GPU performance figures.
The full office gains about 21% in visible width. The measurements are stored in
`artifacts/desktop-office-quality/geometry-camera-final.json`. Texture content
is preserved through Blender's reexport.

## Reproducing the assets and preview

```sh
/opt/homebrew/bin/blender --background --python scripts/blender-office-desktop.py
node apps/desktop/tools/asset-cooker/cook.mjs
/private/tmp/mokaid-desktop-sdk/bin/cmake --build apps/desktop/build/macos-debug --target mokaid_desktop mokaid_metal_smoke --parallel 4
MTL_DEBUG_LAYER=1 apps/desktop/build/macos-debug/renderer/mokaid_metal_smoke apps/desktop/build/assets apps/desktop/build/macos-debug/renderer/shaders /tmp/office-desktop.png 9 1063 491
```

The Metal preview renders through the production renderer. An optional final
argument advances an idle-agent tour by that many simulated seconds; the test
uses fixed simulation steps so captures are reproducible. Rebuild the complete
`mokaid_desktop` target and restart the application after changing runtime or
shader code, so the running executable matches its shaders and assets.

Geometry reports and native captures are under
`artifacts/desktop-office-quality/`. The projection check can be rerun with
`inspect-geometry.mjs` in that directory.

## Validation on the local desktop

- Final full desktop build: 21/21 CTest suites pass in 28.18 seconds, including
  navigation, traffic, actual assets and activities, session lifecycle,
  transport, authorization, feature QML and conversation isolation.
  Network fixtures require permission to listen on localhost. The final log is
  `artifacts/desktop-office-quality/desktop-tests-final.log`.
- Real-layout simulation: all nine actors complete an outing and return to their
  desks within 173 simulated seconds. Fourteen animation clips are observed,
  including two-person coffee, two-person foosball, sofa sitting, chair movement,
  walking and stand/sit transitions. The run checks actor separation and forward
  walking at every simulation sample. Work preemption returns everyone to their
  desks, with all chair offsets restored; interrupted sofa entry and replacing a
  chair occupant also pass. This verifies the covered scenarios, not every
  possible future room layout.
- Web 3D checks: 80 tests in 9 files pass; TypeScript typecheck passes.
- Asset cooker: 10/10 tests pass, including chair parent transforms and exact
  removal of the four geometrically verified obsolete foosball collider boxes.
- Final native Metal scene: nine seated actors, 124 draws and 651,795 triangles.
  Twelve unretained command buffers, resizing with work in flight, and renderer
  destruction pass with Metal API Validation enabled on Apple M4 Pro.
- Mean CPU pose evaluation for nine actors: 0.236 ms with one animation layer,
  0.417 ms with two layers; the last render encoding took 1.72 ms. These are
  CPU measurements from the smoke probe, not an end-to-end frame-rate claim.
- Final chair egress points clear actual furniture triangles by at least 0.36 m.
  Platform height, nine separate chair nodes and parent-local chair translations
  are independently checked against the exported geometry.
- The full local `Mokaid.app` was rebuilt and restarted. The connected Yapio
  workspace loads its five agents, the updated room fills the office viewport,
  and the native window shows the corrected lighting and moving characters.
  Static and activity GPU captures are `native-office-final.png` and
  `native-office-activities.png` in the report directory.
