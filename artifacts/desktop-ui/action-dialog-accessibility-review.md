# ActionDialog cancellation review

No production code changed. The actual ActionDialog and shared controls were loaded in a Qt 6.11 offscreen fixture, with Manrope and the nine Edit agent fields. The test queried Qt accessibility interfaces and sent real Qt key/mouse events.

At 1000×680, 1266×768 and 1440×900, Cancel was visible, enabled and focusable. Its accessible name was `Cancel`, role Button (43), and both invisible/offscreen flags were false after 1.2 seconds. Clicking it closed the form without calling submit.

The observed keyboard sequence is reproduced by the platform tab policy:

- TabFocusAllControls: Name → Shift+Tab → Edit agent → Shift+Tab → Cancel.
- TabFocusTextControls: Name → Shift+Tab → Avatar asset ID → Shift+Tab → Instructions.

This explains the reported keyboard path. The disappearing entry in a native CUA accessibility snapshot was not reproduced by Qt's accessibility interface; this check does not prove the cause of that native snapshot difference. No ActionDialog change is justified by these results.

The separate minimum-shell probe measures the actual QML layout at 1000×680, with synthetic data and a neutral 3D host. Header controls remain within the window in online/offline modes. The office viewport is 728×390, or 394×390 with the 320 px chat. It is a geometry check, not a GPU visual validation.
