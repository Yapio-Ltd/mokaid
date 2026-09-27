# CRM fonts

These unmodified WOFF2 files are served locally so building the CRM never depends on Google Fonts availability or response formatting.

They were downloaded from the official Google Fonts CSS API and `fonts.gstatic.com` on 2026-09-27 using the same browser User-Agent and requests as Next.js 15.5.24. `sources.json` records the exact CSS requests, immutable font URLs, Unicode ranges, file sizes and SHA-256 hashes. All subsets returned by those requests are included, not only the preloaded Latin subset:

| Family | Normal weights | Included subsets |
| --- | --- | --- |
| IBM Plex Sans | 400, 500, 600, 700 | Cyrillic extended, Cyrillic, Greek, Vietnamese, Latin extended, Latin |
| Source Serif 4 | 500, 600, 700 | Cyrillic extended, Cyrillic, Greek, Vietnamese, Latin extended, Latin |
| IBM Plex Mono | 400, 500 | Cyrillic extended, Cyrillic, Vietnamese, Latin extended, Latin |

The stylesheet keeps the original `font-face` declarations, Unicode ranges, `font-display: swap`, family names and weights, replacing only the download URLs. It also retains Next 15.5.24's fallback metrics and the existing `--font-geist`, `--font-display` and `--font-mono` variables. The same four distinct Latin files are preloaded.

IBM Plex is by IBM; Source Serif 4 is by Adobe. Each family is distributed under the SIL Open Font License 1.1. The accompanying `*-OFL.txt` files retain the license text from the official [Google Fonts repository](https://github.com/google/fonts/tree/23e54b51ddffbc7713c583748e3bd86f62b1fa4a/ofl), at the revision recorded in `sources.json`, with line endings and trailing whitespace normalized. Upstream projects: [IBM Plex](https://github.com/IBM/plex) and [Adobe Source Serif](https://github.com/adobe-fonts/source-serif).

`npm run build --workspace @mokaid/crm` checks the local files, hashes, licenses and absence of `next/font/google` imports before compiling. Font updates must update the matching stylesheet, provenance and hashes together; do not add a download step to the build.
