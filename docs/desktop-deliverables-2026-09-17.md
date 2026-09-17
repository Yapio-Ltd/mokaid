# Desktop deliverables · 17 September 2026

The result leads the interface: generated images are visible where they arrive, documents have concise format-aware rows, and opening a result keeps the user inside a focused viewer. The native shell's Manrope typography, neutral dark surfaces and purple selection state are preserved. This is an Operate/Experience surface; controls recede around the artifact.

## Interaction

- Chat and task outputs share the same `DeliveryGallery` / `DeliveryCard` components. Multiple images form a responsive grid; other files remain compact rows. Input attachments are excluded from task output galleries.
- Task deliverables appear before optional “Details & activity”. Drive shows image thumbnails and opens the visible file collection.
- The viewer has a single title, format/size, original download, previous/next and a thumbnail strip. Escape returns to the workspace; Alt+Left/Right navigate the collection. Image controls provide fit, zoom and drag panning; double-click toggles enlargement.
- Two documents remain retained internally so interactive HTML state survives ordinary navigation. Confirmation is reserved for actual form changes; merely clicking or reading no longer marks a document dirty.
- Unknown formats expose an explicit native Quick Look action on macOS and retain original download. Preview support depends on the OS and its installed preview providers; this does not claim universal in-app conversion.

## Formats and boundaries

| Content | Experience |
| --- | --- |
| Supported raster images and SVG | Authenticated inline thumbnail; native image viewer with fit/zoom/pan |
| PDF | Chromium PDF viewer, with its built-in extension explicitly scoped to PDF profiles |
| HTML | Existing isolated interactive document profile |
| Markdown | Readable document rendering |
| Text / code / JSON | Escaped selectable text; JSON formatted where valid |
| CSV / TSV | Table preview, limited to 1,000 rows × 100 columns with a visible truncation notice |
| Audio / video | Player with native controls; supported codecs depend on the distributed Qt build |
| Office / archives / other formats | Native Quick Look on macOS when the OS supports the file, or original download |

Preview and original downloads retain the existing 32 MiB limit, which is stated explicitly for large files. Text/Markdown/CSV input rendering is bounded to 1 MiB with a visible truncation notice; original downloads preserve the full file. Image decoding is bounded to 32 megapixels. Thumbnails are generated off the UI thread, fetched with at most three requests at a time, stored in a bounded private temporary directory and discarded on workspace/session changes. Original temporary files are private and remain alive only while their documents are retained. Quick Look releases its file references before document eviction.

Original files are fetched through the authenticated workspace artifact service. No API credentials enter a WebEngine document, image source URL or external viewer URL. Existing HTML resource restrictions stay in place. The PDF exception applies only to the trusted Chromium PDF extension in a PDF document profile.

## References

The decisions use familiar patterns documented by [Google Drive's file viewer](https://support.google.com/drive/answer/2423485?hl=en-CA), [Dropbox's quick/full previews](https://help.dropbox.com/view-edit/preview), [Dropbox's supported formats and explicit download fallback](https://help.dropbox.com/view-edit/file-types-that-preview), and [Notion's inline files and media](https://www.notion.com/en-gb/help/images-files-and-media). These are interaction references, not claims of equivalent format coverage.

## Validation

Local native build and focused tests cover format classification, escaped table/text rendering, thumbnail generation, curated task outputs, keyboard/mouse gallery opening, responsive layouts and authenticated artifact delivery. The viewer integration fixture uses real PNG bytes, generated PDF bytes and Markdown; PDF verification checks pixels from the actual page rather than only a load event. Screenshots in `artifacts/desktop-deliverables` use explicitly labelled sample data.

Verified locally:

- `mokaid_desktop` and `mokaid_graphics_probe` compile successfully. The graphics probe harness was updated for the viewer's nested WebEngine loader; a GPU benchmark was not rerun.
- `desktop-feature-contracts`, `desktop-feature-qml`, `preview_resource_policy`, and `desktop-preview-formats` pass.
- `mokaid_preview_navigation_tests` passes after its final fixture update: authenticated thumbnail delivery, actual PDF page pixels, image collection navigation, PCM WAV decoding (no autoplay), failed-file retry/download targets, retained-document downloads, and temporary-file cleanup.
- Native Quick Look separately passes a real AppKit smoke test: open, datasource, close/detach, responder restoration and temporary-file eviction. No sanitizer claim is made for that smoke test.
- Independent finish review cleared both identified issues after fixes: exact failed-file recovery and revision-guarded asynchronous document actions.
- Qt reports an existing WebEngineProfile deprecation notice; it does not fail the tests.

No production deployment or live customer mission was performed as part of this change.
