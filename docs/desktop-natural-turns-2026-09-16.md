# Natural turns and closer desktop framing

## Continuous locomotion

The previous follower stopped at route corners above 0.32 radians and discarded
the remaining movement budget at each waypoint. Ordinary routes now round corners
where the body's swept volume fits. The follower anticipates curvature, brakes
before tight bends, interpolates the facing tangent and carries unused distance
into the next curve segment. Animation phase still follows actual distance.

Every rounded segment is validated against room geometry, actors and displaced
chairs. The final chord between simulation frames is checked again. Authored
chair/sofa corridors retain their exact waypoints and timed seating motion.
Corners that cannot safely be rounded retain a deliberate turn.

On the same obstacle slalom at 60 Hz, internal stops fall from six to zero,
stationary turning from 1.0 second to zero, and travel time from 26.8 to 21.8333
seconds. Minimum forward alignment improves from 0.951237 to 0.998885.
See [measurements and trajectories](../artifacts/office-turns/README.md).

New arrival timing exposed an entering colleague blocking another person's sofa
exit. The shared narrow aisle now admits one party: either one visitor or a
coordinated coffee pair. Its reservation lasts until the last person physically
exits. Cancellation, task preemption and agent removal release abandoned claims.

The real nine-person activity/return scenario completes in 148.069 simulated
seconds. A separate 600-second five-person simulation completes 5–7 cycles per
person. These are bounded fixtures, not a claim about every possible crowd.

## Closer framing

The final projected silhouette span changes from 1.94 to 2.08, a 7.22% increase
in apparent size. The outer plinth can crop slightly while desks, activities,
the office heading and the agent dock remain visible. The same projection drives
the 3D view and overhead indicators.

Real-asset tests cover a 1.9 m standing envelope at all 17 activity sockets across
seven viewport aspect ratios. A separate 160-second nine-person movement probe
checks 46,080 projected head/ground points across four aspect ratios, with no
out-of-view samples. Native UI inspection covers full office and chat widths.

- [Camera movement measurements](../artifacts/office-turns/camera-motion-validation.json)
- [Native build tests](../artifacts/office-turns/primary-native-tests.log)
- [Long activity run](../artifacts/office-turns/five-agent-long-probe.log)

## Legal robe repair

The Blender source and the desktop pack now use
`avatar_legal.859687268a64.glb`. Arm weights were removed from the robe, two local
flank panels were rebuilt with their original cloth material, and the wrist
transition was repaired. All 48 animation channels remain byte-identical to the
previous asset. An equal before/after audit covers 9,597 poses and 20 blends:
arm-only robe displacement falls from 264 mm to 0; the new asset has no pathological
edge extension in that audit. The cup handle contact gap is 1.055 mm with no
vertex entering the cup interior. These are measured bounds, not a claim that
every possible pose is perfect.

See [Blender audit and closeups](../artifacts/avatar-life/legal-regression/README.md)
and [final native asset verification](../artifacts/office-turns/final-pack-verification.md).

## Development app

The local app is `apps/desktop/build/macos-debug/app/Mokaid.app`, using the current
`apps/desktop/build/assets` pack. Older `development-stage*` bundles are packaged
snapshots with independent embedded assets; a debug rebuild does not update them.
