# Compact agent indicators

The reusable `AgentIndicators.qml` component uses the existing persistent bridge model. Labels are 34 px high and 96–136 px wide, show the true level when available, and retain full activity detail for the tooltip and accessible button name. Labels ordinarily stay just above the projected head; a thin tether appears when crowding or viewport bounds require displacement.

## Validation

- `qmllint` passes without warnings for `AgentIndicators.qml`.
- The isolated native `mokaid_agent_indicator_tests` target builds; `desktop.agent_indicators` passes.
- Nine labels clustered at all nine center/edge/corner positions remain within both 1063×491 and 653×491 viewports without overlap.
- The dense projection stress runs 120 simulated seconds at 30 Hz per viewport, periodically reverses input order, and checks visibility, dimensions, non-overlap and stable identity at every sample. It passes.
- Small head oscillations do not move label placement; unchanged geometry and input reordering do not reshuffle labels or reset delegates.
- Qt Quick loads the component in a standalone software-rendered view with normal, selected, missing-level, long-name and crowded examples. A pointer click emits the correct selected agent ID. `agent-indicators-preview.png` was inspected at native size.

The standalone visual probe checks the component itself. The root task owns full desktop integration and final application capture. No map, camera, assets or engine behavior changed in this indicator pass.
