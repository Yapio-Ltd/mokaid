# Keyboard, navigation and media serving review

The source integration and final compiled Hero/navigation passed the focused Chromium checks in `keyboard-navigation.json`. This complements the separate three-engine decoder/prerender matrix; it does not repeat that matrix.

The component change in this review adds `tabIndex={enhanced ? 0 : -1}` to the tour skip link. Its loading-stage parent is `aria-hidden`, so the link must stay out of sequential keyboard navigation until the cinematic stage becomes visible.

Verified behavior:

- The ready desktop film is reached with Enter on Experience; the native fragment lands at the CSS header offset.
- Tab reaches Skip the tour. Enter reaches the final presented frame (73.917s at 24fps), and the next Tab starts in the footer. Both the visible payoff and footer retain `/download` links.
- Two Download/Back cycles remove the former landing video and Lenis owner, then restore one readable static story at the saved position. No duplicate video or story is created. The static restoration matches the accepted rule against expanding an already visible section.
- Switching to reduced motion or mobile width removes the media source. Returning to desktop/no-preference keeps that visit static. The mobile menu responds to Enter and Escape.
- The final compiled Hero heading and primary links match the source. Footer destinations are current; removed section anchors are absent.

The original `hero-scene.tsx` has no diff. The landing wrapper's mobile/reduced-motion behavior is intentional and separately covered above.

## Production serving

`production-asset-headers.json` records real HTTP responses from a temporary local Nginx container, using the existing web runtime image and read-only mounts of the current configuration and final compiled directory. It was stopped and removed after the check; nothing was deployed.

The fingerprinted MP4 is served as `video/mp4`, with its correct Content-Length, an ETag, `Accept-Ranges: bytes`, and `Cache-Control: public, max-age=31536000, immutable`. Beginning and suffix byte ranges return 206 with correct Content-Range and exactly 1024 bytes. Conditional revalidation returns 304 with the same successful-asset cache policy. An unsatisfiable range returns 416. The HTML remains `no-cache, must-revalidate`. The MP4 is not gzip-compressed.

The observed cache defect is fixed in `infra/docker/nginx.conf`: `$mokaid_response_cache` retains the existing URI policy for successful/redirect responses and overrides 4xx/5xx with `no-store`. The map is volatile because Nginx Range processing may change a tentative 200 into 416 after the first header pass. The actual 404 now returns only `no-store`. In this Nginx build the late 416 also retains earlier successful-response directives, but the final `no-store` directive forbids caching. This behavior is recorded in the HTTP evidence. The 200/206/304 and HTML policies passed unchanged after the fix.

The deployed CDN/origin is outside this local check. It must preserve Range requests, 206 responses, Content-Range, and the chosen cache headers.

Reproduce the focused checks from `apps/web`:

```sh
node scripts/cinematic-keyboard-navigation.mjs http://127.0.0.1:5173 http://127.0.0.1:4173
node scripts/cinematic-asset-headers.mjs mokaid-meshy-web-runtime:libexpat-fix
```
