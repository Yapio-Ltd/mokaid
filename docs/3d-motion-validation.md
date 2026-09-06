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
