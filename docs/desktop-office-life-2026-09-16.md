# A living desktop office

This pass extends the established native office, its lighting and its physical
traffic system. It adds individual motion, desk gestures, shared leisure,
computer displays and persistent agent labels.

## Motion and activities

The seven avatar rigs have distinct authored gait profiles. Runtime identity
profiles use stable agent IDs, so pace, gesture timing and social rhythm remain
consistent across refreshes. A careful coffee walk, a relaxed walk and a brisk
trip to the foosball table use different poses and speeds. Playback follows
distance travelled at each clip's authored reference speed, including braking.

Desk gestures are staggered rather than sharing a global clock. The sequence
includes focused/relaxed keyboard work, thinking, picking up a phone, a call and
putting it back. A parked phone and its dock remain at the desk when the person
leaves. These instances share the avatar's existing geometry and textures;
surface masks prevent duplicate phones during the handoff to the animated rig.

Social pairs greet each other, talk, laugh and take turns sipping coffee. They
can continue their coffee together on the sofa, facing their neighbour, with
the cup retained through walking and sitting/standing transitions. Returning
coffee is deposited at the machine before the person resumes desk work.

The coffee interaction point moves 15 cm toward the counter to avoid reaching
beyond short arms. At native `(-1.79, 5.23)` it remains navigable with a 0.35 m
body radius. The actual counter surface is 0.702913 m high, 0.45 m ahead of the
new standing position. The phone target is measured against each real desk:
0.30 m to local +X, 0.40 m forward, on a dock whose top is 0.778 m high.
`artifacts/office-life/desk-prop-surfaces.json` records the intersections.

## Computer displays

`scripts/blender-office-screens.py` separates only the existing display faces
and gives them clean local UVs. The room's furniture positions and navigation
remain unchanged. The final room is referenced by SHA-256 in
`assets/office-desktop.json`.

One shared shader header draws code, a graph dashboard and a browser view.
Screens have distinct content and phases, subtle motion and controlled emission.
The animation uses simulation time, so pausing the office also pauses screens.
This is ambient local display content, not a representation of live API results.

Native asset format 4 adds explicit material surface kinds: normal room/avatar,
computer screen, phone, and phone dock. The reader retains format 3 support;
release packaging requires a fresh format 4 cook.

## Agent indicators

Every visible actor carries a compact label with its name, actual API level
when available, and its current visual activity. Labels follow a cached head
joint track, excluding props from head-height measurements. A 31 Hz GUI update
projects the same scene camera into logical pixels; labels remain independent
of render resolution and display scaling.

The model updates existing rows as actors move rather than recreating QML
delegates. A deterministic layout separates grouped labels, with a fine tether
back to each head. Selecting a label opens that person's existing conversation;
keyboard focus and plain-text names are preserved. The established violet/dark
visual system remains in place.

## Validation

Completed checks on the final promoted pack:

- All 23 native CTest suites pass, including transport, session lifecycle,
  conversation selection, navigation, traffic, indicators and the three suites
  that load the final assets. The nine-person activity/return scenario covers
  142.935 simulated seconds. Working desk variations, complete phone sequences,
  paired coffee/sofa conversations and task interruption after a completed sip
  are exercised against the real assets.
- A separate 600-second simulation with five idle colleagues on the real rigs
  completes 4–6 activity/desk cycles per person. Maximum traffic waiting is
  44.9995 seconds; no indefinitely growing wait is observed. This probe uses
  stable name-based fixture IDs, not the live workspace UUIDs. Rendezvous waits
  are separately bounded by 120 seconds. The live UI also showed recovery.
- All seven Blender sources retain their 48 editable actions after reopening.
  Cup contact checks across 42 poses found no hand vertices inside the cup and
  a maximum nearest finger/handle vertex gap of 3.431 mm. Planted-foot drift is
  below 0.969 mm; transition discontinuity is below 0.096 mm. The sources,
  contact sheets and measurements are in `artifacts/avatar-life/README.md`.
- Agent label tests cover projection, nine crowded labels at full-office and
  chat widths (including all four corners and the top edge), stable identity
  on refresh, activity/level updates, actor removal and invalid coordinates.
  An independent 120-second simulation found no label overlaps across 480
  sampled views after the viewport-edge placement fix.
- Native UI inspection confirms the five live Yapio names and real levels,
  changing activity text, and selection from a label into the matching chat.
  The rebuilt `macos-debug/app/Mokaid.app` was relaunched with the final pack;
  connection restoration, illuminated display content and the overhead labels
  were confirmed in the native application. The final UI was checked at full
  office and conversation widths. Observed agents resumed travel after yielding,
  returned to desk typing, picked up a phone and carried coffee between activities.
- Asset cooker: all 12 tests pass, including explicit screen/phone/dock material
  semantics and verified source hashes.
- Web clip compatibility: all 81 tests across the nine 3D suites pass, including
  the 10 animation tests. TypeScript typecheck passes.
- Distribution: 37 relevant tests pass with the new format 4 requirement.
- Three final Metal API Validation captures pass: nine avatars at full-office
  and chat widths during work, plus a social scene after 90 simulated seconds.
  They exercise 12 unretained command buffers, odd-size changes and destruction
  with frames in flight. The final scene has 162 draw calls and 652,525 triangles.
  On this Apple M4 Pro, measured GPU means were 1.95–2.21 ms and CPU encoding
  means 2.92–3.43 ms. These offscreen Debug measurements are not full-application
  frame-rate or target Mac M1 claims.
- All six HLSL shader entry points compile with DXC 1.9 strict mode and warnings
  as errors. Windows D3D11/D3D12 integration still requires a Windows machine.

The broader pose review also found an imported Legal mesh defect: hand
influences reached the skirt, and some faces physically joined a hand to the
robe. Weight normalization alone did not detect this. The Blender repair
separates those surfaces and closes each boundary independently; validation
therefore also checks deformation of the repaired edges. The final Legal asset
passes the 8× maximum edge-stretch guard at 7.714× across the deformation sweep.

Detailed final records:

- `artifacts/office-life/native-final-tests.log`
- `artifacts/office-life/native-final-tests-detail.log`
- `artifacts/office-life/native-five-agent-long-probe.log`
- `artifacts/office-life/native-final-render-validation.json`
- `artifacts/office-life/final-desk.png`
- `artifacts/office-life/final-chat.png`
- `artifacts/office-life/final-social.png`
- `artifacts/desktop-office-quality/review-indicator-boundaries-fixed.log`
