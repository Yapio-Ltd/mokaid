# Desktop interface aligned with the supplied reference

## Scope

The desktop now uses a floating midnight sidebar, restrained violet selection,
thin vector icons, a search pill, compact connection controls, Manrope typography,
and consistent rounded panels and forms. The office has portrait team cards,
real levels/progress, an agent entry point, and responsive workspace statistics.
The shared controls also update feature pages, chat, search/notifications,
forms, file navigation, deliverable previews, preferences and account menus.
Profile, members, integrations and billing remain reachable through the account
card/menu. Existing workspace/draft/preview protections remain in place.

The supplied image is a visual reference, not sample account data. Counts, names,
levels, presence and progress come from the controllers. Working now counts the
API's working status. The profile uses the actual account name and an initial.

Seven 384×384 portraits were rendered in Blender from the actual character
models. Their head/shoulder crop is consistent; Legal uses the corrected 859687
asset. The decorative brand orb is a separate Blender render. All images and the
licensed Manrope font are bundled locally, with no new remote-image dependency.
See `apps/desktop/presentation/assets/provenance.json` and
`scripts/blender-desktop-portraits.py` for reproducibility.

## Agent indicators

Indicators are 34 px high and 96–136 px wide. Name, level, activity and a status
dot remain visible; full descriptions remain accessible by tooltip and assistive
technology. Position hysteresis and subpixel filtering reduce movement. A tether
appears only when the label must be offset from the agent.

An integration check exposed label animations crossing between two otherwise
valid layouts. The component now applies the resolved layout directly, keeping
the model's stability filtering. A real Qt/model replay with nine agents in a
700×600 view measured 198 overlapping displayed samples before and zero after.
See [indicator reflow validation](../artifacts/desktop-ui/agent-indicators-reflow-validation.md).

## Map preservation

This interface redesign does not change map geometry, materials, lighting,
renderer settings or camera parameters. The office asset remains
`office.desktop.fe4052470911.glb`. Existing viewport margins remain 74/100 px.
The view responds normally to the space available when opening chat or resizing.
The earlier locomotion, robe and camera work is documented separately in
[natural turns and framing](desktop-natural-turns-2026-09-16.md).

## Validation

- Native macOS app compiled and opened with the new interface and bundled assets.
- Visual inspection: full office, compact labels, portrait cards, Agents list,
  record details, edit form and conversation panel. Follow-up fixed clipped
  statistic captions, connection alignment and the normal-size Settings row.
- Feature contracts and QML suites: PASS (6.99 seconds combined). Their fake HTTP
  server requires localhost; the first sandbox attempt could not bind, and the
  rerun with localhost access passed. Cooker suite: 12 PASS.
- Existing primary engine/navigation/traffic/indicator checks and final real
  asset/activity/navigation checks: PASS. Three Metal validation renders passed.
- Additional Qt fixtures measured the shell at 1000×680 (including 320 px chat),
  and preferences/profiler at 613/565 px high. Menu semantics and cancel/discard
  signals passed. The ActionDialog Cancel button was independently checked at
  three sizes after CUA reported inconsistent accessibility snapshots; Qt
  confirmed it remained visible, enabled, accessible and functional.
- The macOS text-only tab focus policy explains skipping buttons with Tab;
  full keyboard focus mode includes them. No system preference was changed.

Logs and bounded review reports are in `artifacts/desktop-ui/`.
The native render evidence is in `artifacts/office-turns/`.
Windows was not run in this macOS environment. Visual similarity is verified by
inspection; no claim of an automated pixel-for-pixel comparison is made.
