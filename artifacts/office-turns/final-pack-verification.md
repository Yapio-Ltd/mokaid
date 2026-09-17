# Final Legal pack verification

Pack manifest SHA-256: `46f8efc2ccd8de836da3055a957838ba7048811bd8e9c83f752feba3f0b0437b`.

Legal source SHA-256: `859687268a642c7644714cee5ebd5e9f72b6a4835c62140122f3f965f3364198`.

## Primary native checks

| Check | Result | Elapsed |
|---|---|---:|
| desktop.office_activities | PASS | 37.94 s |
| desktop.real_assets | PASS | 7.18 s |
| desktop.real_navigation | PASS | 0.26 s |
| desktop.agent_indicators | PASS | 0.43 s |

The indicator target alone was rebuilt in the primary build. Main/QML and the native engine were not edited or rebuilt for this verification. The real-pack tests confirm 48 clips per avatar, all nine movable desk routes, three sofa exits and five standing activities. Legal's seated sole height is −0.570 mm relative to the floor; the seated pelvis is 0.510 m. The nine-agent activity fixture completes each first trip and return by 148.069 simulated seconds and observes the coffee, phone, chair and sofa activity sequences.

## GPU verification

`verify-render.py` passed all three cases with Metal API Validation on Apple M4 Pro: desk/work at 11 s (1807×835), compact chat scene at 71 s (1110×835), and social scene at 100 s (1807×835). Each case contains nine agents, 161 draw calls and 652,526 triangles. All pass the 12 unretained command-buffer, resize and renderer-destruction checks.

The three PNGs were inspected. Legal's robe remains compact around the seated/standing body without the previous arm-to-skirt stretching in these samples; the room, other avatars and props render normally. These are sampled scenes, not a guarantee for every possible pose. The authored asset's broader deformation validation is recorded separately by the Blender task.

GPU mean times range from 1.52 to 2.77 ms; CPU encode means from 4.18 to 4.37 ms. These are debug offscreen measurements, not whole-application FPS. Native tests and GPU verification ran concurrently, so wall-time simulation spikes in the detailed test log include contention and must not be interpreted as isolated UI frame timings.

Evidence: `final-native-tests.log`, `final-native-tests-detail.log`, `final-indicator-tests.log`, `native-render-validation.json`, `final-desk.png`, `final-chat.png`, and `final-social.png`.
