# Cinematic story: WebP frame packs (28 September 2026)

Scroll storytelling no longer seeks an MP4. Dual fingerprinted WebP packs are drawn on a canvas in cover mode (fullscreen on mobile, no letterbox bars).

## Packs

- Digest: `10b39734a90b`
- Desktop: 1280×720, 24 fps, 1776 frames (~133 MB)
- Mobile: 960×540, 12 fps, 888 frames (~49 MB)
- Quality samples vs master: PSNR ≈ 36–38 dB at scroll waypoints

## Verification

- Vitest: 306 tests passed
- TypeScript + scoped ESLint + `build:seo` passed
- Playwright fixture + `--final` on Chromium, Firefox, WebKit passed
- WebKit visibility resume passed
- Reports under `verification/`

## Commands

```sh
cd apps/web
npm test -- --run
npm run typecheck
npm run build:seo
npx vite preview --host 127.0.0.1 --port 5197
node scripts/cinematic-story-browser.mjs http://127.0.0.1:5197 chromium,firefox,webkit --final
node scripts/cinematic-story-visibility.mjs http://127.0.0.1:5197
```
