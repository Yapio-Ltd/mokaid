# WebKit initial readiness investigation

The production MP4 decodes successfully in an isolated WebKit 26.5 video element: 1920 × 1080, 74 seconds, loadeddata. H.264 High/level 5.0 was not the cause of the observed landing failure.

Before the fix, the landing issued no MP4 request and received no media events. Its initial React effect ran with document.readyState=interactive and document.styleSheets empty. The unstyled hero placed #product at 469px inside the 900px viewport; the progressive-enhancement guard therefore locked it into static mode. Once CSS loaded, the same section was at 1620px. See webkit-before-css-gate.json.

CinematicStory now waits for applicable pending stylesheets to load or error before measuring entry. The window load event covers replaced stylesheets. All listeners are removed on cleanup. Ineligible devices still never create a video, and an already-visible section remains static. The media controller and encode are unchanged.

Validation completed: 18 focused component/controller tests pass, including delayed CSS and entering while CSS is pending; TypeScript passes. Final production rerun passes all assertions in Chromium, Firefox and WebKit, using the original fingerprinted 1080p film. WebKit completed 16 seek samples (median64ms, maximum542ms, maximum error1.008frames), plus reverse/large jumps, latest-target coalescing, loading failures, delayed responses, mobile/reduced-motion and no-JavaScript checks. See final-media-summary.json. A separate Firefox navigation timeout traced to a12.7-second remote font download; the browser harness now waits for DOM/CSS and the tested media state, rather than a global load event.
