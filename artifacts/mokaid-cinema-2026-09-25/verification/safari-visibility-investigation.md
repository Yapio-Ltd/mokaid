# Safari visibility investigation

No production code was changed in this investigation.

The component intentionally suspends seeking while `document.hidden` is true. ScrollTrigger may still replace the pending target, but the movie and captions hold the last presented frame. On hide, the controller also clears its decoder timeout baseline so time spent in the background is not mistaken for a decoder failure. A suspended animation ticker or compositor can likewise leave the visible frame unchanged while native scrolling still moves the page.

## Targeted application regression: PASS

`visibility-webkit.json` records WebKit 26.5 with the actual fingerprinted 1080p movie. The test overrides the page visibility getters and dispatches `visibilitychange`; the real decoder and production GSAP ticker remain active. Screenshot tracing keeps this automated window compositing.

At 20 s, the test hides the page and changes scroll targets through 55 s, 7 s, 42 s and 51 s. No extra seek occurs while hidden. After showing the page, exactly one seek reaches the latest 51 s target in 240 ms, with media still paused and no error or recovery UI. A subsequent reverse seek to 7 s succeeds.

From `apps/web`:

```sh
node scripts/cinematic-story-visibility.mjs http://127.0.0.1:4173
```

## Diagnostic without screenshot tracing

The same WebKit test without tracing cannot complete its baseline presentation assertion, before any simulated hide. After 8 seconds, native `currentTime` is 20 s, `seeking` is false, `readyState` is 4 and `paused` is true, but the last frame callback and rendered-caption time remain 0 s. There are no page errors. See `visibility-webkit-uncomposited.json`. The diagnostic intentionally exits nonzero when presentation is not observed:

```sh
node scripts/cinematic-story-visibility.mjs http://127.0.0.1:4173 --no-trace
```

This demonstrates a difference associated with compositor activity in the automated environment. It supports—but does not establish—the hypothesis that the inactive native Safari window was occluded or throttled. The native Safari observation has no JavaScript visibility/callback inspection, and a foreground native Safari scroll run remains unverified. Neither this simulated visibility test nor the three-engine suite establishes real OS background/foreground behavior or physical-device performance. The full browser suite uses screenshot tracing and its results should be read with that limitation.
