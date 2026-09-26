# Cinematic controller — synthetic fixture verification

All checks passed on the installed Playwright Chromium 151.0.7922.34, Firefox 153.0 and WebKit 26.5 engines.

This run uses a disposable FFmpeg test pattern: **74 seconds, 320×180, 24 fps, H.264, GOP 6, no audio**, served through correctly implemented HTTP 206 byte ranges. It validates browser control and decoding behavior, **not the Higgsfield film, production-size decoding performance, native Safari or physical mobile devices**.

Verified in each engine:

- First presented frame and full `[0, 74]` seekable range before cinematic promotion.
- Authored scroll milestones, reverse to zero, large jumps (74→0 and 72→2), and latest-target coalescing.
- Media remains paused, muted and inline; overlays follow presented frame time.
- Five final notifications, fully opaque final CTA, and caption-free exit interval.
- Mobile viewport and reduced-motion modes issue no video request; three illustrated moments and the download CTA remain available.
- A failed media request preserves the static fallback.
- Entering the section before readiness locks its static layout; no late height change.
- Compatibility path with `requestVideoFrameCallback` removed uses `loadeddata`/`seeked` successfully.

No browser-specific production fix was needed. Firefox exposes the `playsinline` attribute without a `playsInline` JavaScript property; the test checks the attribute.

The adjacent `fixture-chromium.json`, `fixture-firefox.json` and `fixture-webkit.json` record timestamps, engine versions, seek samples and range requests.

Reproduce from `apps/web` with a running Vite/preview server and FFmpeg installed:

```sh
node scripts/cinematic-story-browser.mjs http://127.0.0.1:5173
```

An optional third argument selects engines, for example `firefox,webkit`. Each engine runs in an isolated browser. Failures save a screenshot and trace next to its JSON report.
