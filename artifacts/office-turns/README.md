# Continuous native turns

The old follower stopped at direction changes above 0.32 radians and discarded movement left over after reaching each waypoint. The same deterministic slalom now has 0 internal stops (previously 6), with 0 seconds of stationary turning (previously 1.0). Travel time drops from 26.8 to 21.8333 seconds.

`trajectory-before.csv` and `trajectory-after.csv` contain the same fixture at 60 Hz: time, position, yaw, speed and distance. `trajectory-probe.cpp` defines the fixture. The baseline was reproduced from the Traffic implementation recorded at the start of this pass; its summary matches the original pre-edit probe in `artifacts/office-life/native-corner-before.log`. `locomotion-comparison.json` records all numeric comparisons.

Rounded ordinary routes are checked against the physical navigation geometry, occupied actor discs and moved chairs. The follower anticipates curvature speed constraints and interpolates tangents. Its final frame-to-frame chord is checked again, including swept actor/furniture guards. Caller-verified seat corridors keep their exact waypoints, and timed seating/chair poses keep their existing translation curves. Unroundable tight corners still stop safely.

A timing change exposed a separate sofa admission interlock: an entering actor could block a seated actor's standing corridor. The narrow sofa aisle now admits one party (a solo visitor or a coordinated coffee pair) until its final participant exits. No collision or rendezvous timer was relaxed.

Validation: `native-tests-detail.log`, `traffic-tests.log`, and `five-agent-long-probe.log`. Real route geometry smoothing metrics and the standalone probe are recorded in `real-navigation-smoothing-summary.json`.
