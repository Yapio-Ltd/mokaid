# Office quality and immersion — 2026-09-25

The reference is the user-supplied `office.png`. These captures run the production
Qt Quick office and native Metal viewport with isolated, synthetic task/agent
records. They do not use a signed-in workspace or send real messages.

## Result

- Mirrored floor reflections with roughness-aware filtering, improved environment
  lighting and edge smoothing, and narrow/wide emission bloom.
- Twelve neighboring workstations, corridor glazing, plants, and an immersive
  ceiling replace the empty surroundings. Overview keeps the office open.
- Physical monitors display their assigned task's title, progress, connection
  state and recent server-reported actions. Two previously unequipped seats now
  have monitors. Spare unassigned monitors stay dark.
- Screen content updates from task fetches and workspace events, with periodic
  reconciliation for missed events. Terminal HTTP results cannot be overwritten
  by older running events. Only display fields are copied into the screen atlas.
- Active task labels and screens animate; reduced-motion and offline states
  suppress misleading activity.
- Seventeen collision-validated destinations are available through projected
  floor markers and the route map. Selecting an agent approaches their desk,
  faces them, then opens the conversation. Recognized character rigs smoothly
  rest their hands and turn their head/chest toward the visitor.

## Captures

- [Overview](office-tour-overview-wide.png): floor reflections, glow, neighboring
  desks and work labels.
- [Entrance](office-tour-entered-wide.png): eye-level environment and floor markers.
- [Conversation](office-tour-chat-wide.png): arrival at the selected desk and
  the agent facing the visitor.
- [Minimum content size](office-tour-chat-shell-minimum.png): conversation and
  navigation controls fit the desktop shell's available area.

## Validation and limits

The complete macOS desktop application builds. Nine targeted CTest suites pass:
surroundings (synthetic and authored assets), guided tour (synthetic and authored
assets), task/conversation controller, screen ownership/content, floor anchors,
explicit navigation cancellation, and the native Metal/QML interaction flow. Six additional engine/navigation,
traffic/activity and authored-asset checks also passed during integration.
The engine tour suite passed UBSan. Native GPU checks used Metal API validation;
atlas replacement/reuse/removal was exercised with frames in flight. Detailed
renderer evidence is in [the renderer capture guide](../office-renderer-2026-09-25/README.md).

The screens visualize task/action telemetry exposed by the server; they are not
a remote desktop video stream. Existing character identities and source meshes
are preserved. Unknown custom rigs retain their authored animation instead of
receiving unsupported bone rotations. Windows shader/source parity was reviewed,
but no Windows GPU or DXC was available for execution. ASan could not run in this
environment (even a minimal executable stalled before main); no ASan pass is claimed.
