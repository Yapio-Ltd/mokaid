# Cinematic story: responsive video and navigation recovery

The video story now runs on touch phones, tablets and desktop viewports. The previous implementation intentionally excluded touch/narrow screens and permanently selected the illustrated layout whenever the section entered the viewport before media readiness. That also disabled the story on restored/mid-page visits.

## Changes

- Removed viewport/pointer eligibility and the permanent early-entry lock.
- Reserved the same 1300svh scroll track during loading and playback. Delayed video catches up to the current scroll position without changing the section height.
- Recreate/dispose each video's controller and ScrollTrigger with the component; synchronize on page visibility/history restoration.
- Begin decoding/seeking from metadata when needed, without requiring the entire film's seekable range or a paused video's first presentation callback. Captions remain tied to decoded/presented frames.
- Preserve the track on media errors and offer Retry at the current scroll position. After 12 seconds of loading, offer Retry while continuing the existing download.
- Adapt captions, progress and all five completion notifications to portrait and short landscape. Portrait shows the complete landscape film.
- Retain semantic illustrated content for no-JavaScript and reduced-motion preferences; changing the preference back restores video without a reload.

## Verification

- Full Vitest suite: **311 tests in 41 files passed**. TypeScript, scoped ESLint and the production build passed.
- Real 74-second 1080p H.264 film tested in Chromium, Firefox and WebKit. Reports are under `verification/`.
- Each engine covers desktop, touch phone, touch tablet, portrait/landscape rotation, SPA navigation back/home, direct story hash entry, forward/reverse seeks, captions, failed-load retry, delayed-load retry/catch-up, and reduced-motion changes.
- The pending-load test advances beyond the former 12-second cutoff and verifies the same source and section height remain intact before successful readiness.
- Separate 16 KiB/s byte-range stream check preserves loading/video/skip controls.
- WebKit visibility regression verifies scrubbing after hidden/offscreen conditions.
- The complete WebKit actual-media suite also passed against the final production build and a fresh homepage snapshot; see `verification/production/`.
- Representative real-media screenshots and measured layouts are under `layout/`; checked 390×844, 320×568, 768×1024, 844×390 and 568×320.

These are automated desktop browser engines with touch/mobile viewport emulation, not physical iOS/Android device tests. No deployment was performed.

## Commands

From `apps/web` (requires installed Playwright browsers and ffmpeg/ffprobe):

```sh
npm test -- --run
npm run typecheck
npx eslint src/components/landing/cinematic-story.tsx src/lib/cinematic-video-controller.ts src/test/cinematic-story.test.tsx src/test/cinematic-video-controller.test.ts
npm run build
# Browser regression also requires a prerendered dist/index.html for its no-JS check.
node scripts/cinematic-story-browser.mjs http://127.0.0.1:5197 chromium,firefox,webkit --final
node scripts/cinematic-story-bandwidth.mjs http://127.0.0.1:5197 16
node scripts/cinematic-story-visibility.mjs http://127.0.0.1:5197 --no-trace
```

The browser and bandwidth scripts accept `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` for an existing Chrome executable. Browser evidence can be directed elsewhere with `CINEMATIC_STORY_REPORT_DIR`.
