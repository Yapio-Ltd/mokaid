# Mokaid cinema — reproducible native edit

Sources come exclusively from the recorded Higgsfield jobs in `../production-manifest.json`. These scripts do not submit generation jobs or spend credits. They use the same narrative cues as `apps/web/src/data/cinematic-story.json`.

## Requirements

Node 20+, ffmpeg/ffprobe with libx264, curl, zip, and native Higgsedit with `p.cut`, `p.compose`, shaped font assets, and `--bitrate`. The exact existing `Manrope.ttf` is vendored and imported with `p.add`; native typography uses its `wght` axis at 400/700. The authenticated Higgsfield sandbox has the CLI at `/usr/local/bin/higgsedit`; its authoring schema is `/opt/fable/types/fable.d.ts`. A local machine needs its own native installation to render. No browser renderer is used.

## Prepare and render

From this directory:

```sh
node prepare-media.mjs --framing ../framing-review.json
node export-films.mjs
```

`prepare-media.mjs` accepts `--manifest`, `--story`, `--logo`, `--font`, `--framing`, `--out`, `--formats social-16x9,social-4x5,social-9x16,web`, and `--force`. Default paths resolve from this repository. Whole generated takes are retimed to the approved 7, 6, 7, 12, 10, 9, 10, 6, 7 seconds, preserving the last-frame chain. Audio is pitch-preserved and given 55 ms edge fades to prevent clicks. There is no added speech or substituted stock music. Missing source audio is reported rather than concealed.

The source manifest uses `clips: [{index,id,jobId,url,localPath,sourceDuration,outputDuration,status}]`. Relative `localPath` is resolved against that manifest's directory. Optional `framing` by format accepts `{localPath?,sourceUrl?,focusX:0.5,focusY:0.5,reviewed:true}`; a portrait source generated through Higgsfield can replace a crop. Focus coordinates range from0 to1. Optional `panX` / `panY` objects `{from,to,start,end}` move that crop with smoothstep easing in output seconds. Central crops are review defaults and remain flagged until approved.

`--framing` reads a separate review file with `overrides:[{index,framing,audioGainDb}]`, merges it into the build's copied manifest, and leaves the production source manifest untouched. Approved scene5 gain is−15dB; all other gains default to0. The exact existing Manrope font and its `OFL-Manrope.txt` license are bundled. `analyze-audio.mjs` measures source loudness/envelopes read-only; these measurements are not an audio listening review.

Picture and sound are retimed independently before muxing. This avoids a reproduced ffmpeg 7/macOS scheduling stall with the generated audio-first MP4s. Partial files are written under separate names and become prepared media only after duration, dimensions and audio validation succeed.

```sh
MOKAID_PRODUCTION_ROOT=/absolute/path/to/build node export-films.mjs --build-only
MOKAID_PRODUCTION_ROOT=/absolute/path/to/build MOKAID_FORMAT=social-9x16 higgsedit build build-film.mjs
higgsedit frame build/projects/social-9x16 72.5 --out renders/payoff.png
higgsedit render build/projects/social-9x16 --range 67:74 --out renders/payoff-review.mp4
```

`MOKAID_FORMATS` restricts export formats; `MOKAID_EXPORT_DIR` selects the delivery directory. `--force` rerenders native films. `--skip-archive` allows each format to be rendered and uploaded separately within the sandbox lease; a later invocation writes the editable archive. Separate invocations merge verified formats into the delivery manifest. Existing source/prepared media are reused only while a hash of the source, framing, timing and gain matches, so corrected takes or crops invalidate prepared caches automatically.

An approved inverse camera take can set `reverseVideo:true,useDefaultAudio:true` in its framing override. Only its picture reverses; generated audio from the original horizontal scene is retimed forward with unchanged pitch. This avoids reversed coffee/room sound. Reversed actions and both endpoint matches still require creative review.

## Deliveries and review

- Native editable projects at `build/projects/<format>`, each with imported media, original brand mark, independent native title/notification layers, and provenance.
- Three H.264 films, 74 seconds/24 fps, at 1920×1080, 1080×1350, and 1080×1920, with generated sound normalized to a restrained -20 LUFS target.
- Silent 1920×1080 web video, fixed 24 fps, a maximum quarter-second GOP (6 frames), no B-frames, front-loaded MP4 index. A SHA-256 fingerprinted copy is provided for `/assets/`.
- `delivery-manifest.json` records actual dimensions, duration, audio presence, size, and SHA-256; `mokaid-higgsedit-editable.zip` packages projects and authoring inputs. This is an editable archive, not a hosted editor link.

Inspect every source boundary, cue, notification and the original logo from the shared manifest's `logoAt` (71.2 s) through 74 s. The final CTA text also comes from that manifest. Review portrait action visibility at every scene, not just the frame center. Rendering does **not** mark those creative checks passed. The web encoding still requires actual browser seeking tests and an HTTP server supporting Range requests.

After extracting `mokaid-higgsedit-editable.zip`, the prepared media and all authoring inputs are already present. From the extracted archive root, rebuild any social format with:

```sh
MOKAID_PRODUCTION_ROOT="$PWD" MOKAID_FORMATS=social-9x16 node authoring/export-films.mjs --skip-archive
```

This rebuild imports the bundled media into native projects at the new location. It requires no generation jobs or credits. To change a source or framing rather than just graphics, call `authoring/prepare-media.mjs` with explicit `--manifest`, `--story`, `--logo`, `--font`, `--framing`, and `--out` paths; accepted source URLs and alternate-take provenance are included in the manifests.

## Higgsfield sandbox lifetime

The sandbox may expire after a foreground call. Transfer this production folder, generated input files and assets as a recoverable bundle before rendering. Reserve output upload URLs before a long job; run the render and PUT its delivery/archive in the same background command, then confirm only successful uploads. Poll the background status and preserve the log. Do not assume `/home/user` is a durable deliverable, and coordinate render concurrency with frame extraction/generation work.
