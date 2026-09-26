# Final 1080p media verification

Actual-film execution on 2026-09-25: **PASS in Chromium 151.0.7922.34, Firefox 153.0 and WebKit 26.5** after correcting the initial CSS-readiness measurement. All three engines used the unchanged production 1080p MP4, fingerprint `adac1c365481`, with no fixture substitution. See `final-media-summary.json` and the three individual reports.

| Engine | 16 seek samples: median | p95 / maximum | Maximum presented-time error |
| --- | ---: | ---: | ---: |
| Chromium | 49 ms | 85 ms | 1.008 frames |
| Firefox | 78 ms | 131 ms | 0.072 frames |
| WebKit | 63 ms | 664 ms | 1.008 frames |

These automated settle times include concurrent engine execution and large jumps; they are not a measured rendering frame rate or a guarantee for every device. The first WebKit failure was an unstyled-layout measurement before CSS loaded, not a codec failure. The component now defers its initial geometry check until applicable stylesheets settle. The harness waits for DOM/CSS and tested states rather than unrelated remote font downloads. Synthetic-fixture results remain separate.

## Run after the final film is available

The shared manifest must already reference its fingerprinted `.mp4` in `apps/web/public/assets`. Build and prerender the final site, then serve that build. For example, from `apps/web`:

```sh
npm run build:seo
npm run preview -- --host 127.0.0.1 --port 4173
```

In another terminal, from `apps/web`:

```sh
node scripts/cinematic-story-browser.mjs http://127.0.0.1:4173 chromium,firefox,webkit --final
```

The command reads the existing manifest, checks the local media with `ffprobe`, records its SHA-256, and exercises the **actual URL, server headers and video bytes**. It does not write the manifest, replace public media, generate a fixture or affect another browser session. Normal playback requests continue to the supplied server. Separate browser contexts simulate missing/delayed media.

Prerequisites: final MP4 is H.264, 1920×1080, 24 fps, approximately exactly 74 seconds, without an audio track; filename contains an 8–64 character hexadecimal fingerprint; FFprobe and all three Playwright engines are installed. The server must return a valid HTTP 206 response for `Range: bytes=0-1023`.

## Assertions and measurements

- All three engines: first presented frame and complete seekable timeline before enhancement; muted, paused and inline media throughout.
- Milestones and large/reverse jumps: `7, 13, 20, 32, 42, 51, 61, 67, 74, 0, 72, 2, 55, 18, 65, 74` seconds; coalescing to the last of several rapid scroll targets.
- Each sample records requested time, clamped target time, presented frame time, absolute error in seconds/frames and settle time. Summary records count, median, p95, maximum settle time and maximum frame error. The readiness assertion accepts less than 0.1 seconds of presented-time error; these timings describe the automated run, not a claimed field frame rate.
- Five notifications, fully visible final CTA, caption-free exit, and final payoff screenshots.
- Mobile viewport and reduced motion: zero MP4 requests, three illustrated moments, reachable download CTA and no horizontal overflow.
- Missing MP4: static fallback. Entry before readiness: no later layout expansion. Initial media response delayed by 3 seconds: safe readiness and forward/reverse seeking. The delay is a response-latency simulation, not a sustained throughput throttle.
- Compatibility path without `requestVideoFrameCallback`.
- Existing `dist/index.html` loaded with JavaScript disabled: three visible moments, CTA, no video elements, film layers or MP4 requests.

Reports are written as `final-media-{chromium,firefox,webkit}.json`, `final-media-summary.json` and payoff screenshots in this folder. Failure screenshots and Playwright traces are retained. All engines run independently in parallel; timing is affected by concurrent execution.

## Prerender already checked

The current build passed no-JavaScript checks in Chromium 151.0.7922.34, Firefox 153.0 and WebKit 26.5: three illustrated moments, visible CTA, no film layers and no MP4 requests. Reports: `prerender-nojs-{engine}.json`, including the HTML snapshot hash. This confirms the current snapshot only; the final command checks the rebuilt snapshot again.

To repeat only that check without loading either video fixture or final media:

```sh
node scripts/cinematic-story-browser.mjs http://127.0.0.1:4173 chromium,firefox,webkit --prerender-only
```

Creative continuity, native Safari and physical mobile-device behavior remain outside this automated check.

## Additional real-bandwidth check — passed

After the final fingerprinted film and preview server are available, run from `apps/web`:

```sh
node scripts/cinematic-story-bandwidth.mjs http://127.0.0.1:4173 16
```

This Chromium-only supplement opens an isolated local proxy, forwarding the preview site while streaming the **actual MP4 file** at **16 KiB/s aggregate across every media connection**, in 1 KiB chunks. It implements HTTP 206/416, open-ended ranges and suffix ranges. It does not replace the manifest, alter public files or interfere with an already-open preview. An unfingerprinted source is rejected before starting a server or browser.

The test waits for at least 4 KiB of real body data, enters while the film is still unready, and verifies that the page locks the static version: three illustrated moments, no remaining video element, a decoded office illustration and a usable download CTA. It saves a screenshot, per-range status/byte/timing counters, and the before/after states. This validates a nonblank fallback under low throughput; it does not claim 1080p seek catch-up on that connection.

Execution is bounded to 9 seconds of browser activity. At the default rate the media-transfer budget is at most 144 KiB plus a 1 KiB scheduler burst. The optional rate argument accepts 1–128 KiB/s; use the default 16 for the deliberate unready-on-entry scenario. Browser, streams, timer and local server close afterward.

Output: `final-media-bandwidth-chromium.json` and a screenshot, with trace/screenshot evidence on failure. The real-film test passed at16KiB/s on2026-09-25:4,096bytes crossed a206response before entry, the request was cancelled, and all three illustrated moments, a decoded image and the CTA remained available. The proxy's isolated8KiB transport unit tests also passed:

```sh
node --test scripts/cinematic-media-throttle.test.mjs
```

## Additional visibility investigation

The targeted WebKit application hide/show regression passes: media holds while hidden, then seeks once to the latest pending 51 s target in 240 ms and reverses to 7 s. This uses simulated `document.hidden`/`visibilitychange` with the real film and screenshot tracing. Without tracing, a separate diagnostic finishes the native seek (`currentTime=20`, `readyState=4`, `seeking=false`) but receives no corresponding presented-frame callback within 8 seconds. Native Safari foreground/occlusion behavior therefore remains unverified; this is not a native Safari pass claim. See `safari-visibility-investigation.md`, `visibility-webkit.json` and `visibility-webkit-uncomposited.json`. No production change was made for this observation.
