# Indicator reflow regression

The endpoint layout solver already prevents overlap, but independent QML `SmoothedAnimation` behaviors on each badge's x/y position display intermediate or delayed coordinates that are not checked by that solver. Real moving labels can cross or cover each other during reflow.

## Reproduction

A 700×600 Qt Quick software-rendered view loads the real `AgentIndicatorModel` and `AgentIndicators.qml`. Nine moving, tightly clustered actors are projected at 30 Hz, with periodic input-order reversals. The harness checks the displayed QQuickItem rectangles every approximately 4 ms for two seconds; model target rectangles are independently checked after each update.

| Revision | Displayed-position samples | Samples with overlap | Model target overlaps |
|---|---:|---:|---:|
| Before | 411 | 198 | 0 |
| After | 417 | 0 | 0 |

The additional numeric probe identifies the first unsafe interpolation at model frame 6 (0.2 s): agents 3 and 4 swap their vertical layout order, while both endpoint layouts remain separate. At 13% interpolation, their intersection is 86.93×0.45 px.

## Correction

Removed only the badge x/y animation behaviors. Coordinates now use each complete model-resolved layout. The model's existing head-motion filtering, placement hysteresis and persistent delegate identity remain active. Map, camera, engine and model logic are unchanged. The `reducedMotion` public property remains compatible with the root component API.

`qmllint` passes without warnings; `git diff --check` passes. Before/after PNGs and probe sources are retained alongside this report. The standalone compiled probe is at `/private/tmp/mokaid-indicator-reflow/build/indicator_reflow`; it loads the staged component from that directory, which was refreshed from the corrected source before the passing run.
