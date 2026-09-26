# Native render recovery

Confirmed checkpoint (web project, prepared horizontal media, source manifest, font/license, authoring):

https://d2ol7oe51mr4n9.cloudfront.net/user_3IzyO73Zdrk1FRjgePW5mupmEs9/ca93d367-008e-4d84-b991-f601c2e21f7d.zip

Restore the ZIP into `/tmp/mokaid-native-final`. Update `production/` from this local directory and `framing-review.json` from the parent artifact directory. Copy `credits-ledger.json`, `portrait-manifest.json`, `portrait-office-manifest.json` into `build/` before packaging. The checkpoint predates the final portrait overrides and therefore must not be used without the updated review file.

Run preparation once using all formats:

```sh
node production/prepare-media.mjs --manifest production-manifest.json --story cinematic-story.json --logo mokaid-logo.png --font Manrope.ttf --framing framing-review.json --out build --formats web,social-16x9,social-4x5,social-9x16
```

Then render one format at a time and upload the result before the same background command exits:

```sh
MOKAID_PRODUCTION_ROOT=/tmp/mokaid-native-final/build MOKAID_FORMATS=social-4x5 node production/export-films.mjs --skip-archive
MOKAID_PRODUCTION_ROOT=/tmp/mokaid-native-final/build MOKAID_FORMATS=social-9x16 node production/export-films.mjs
```

The final invocation creates `build/deliveries/mokaid-higgsedit-editable.zip`. Upload video with the presigned slot's returned `content_type` (normally `video/mp4`). ZIP slots return `application/octet-stream` even when ZIP was requested; use that exact returned type to avoid a403 signature error. Confirm only after HTTP200.

The ephemeral upload slots are stored separately at `/private/tmp/mokaid-export-recovery-upload-slots.json`. Do not commit that file. Current confirmed web and16:9 outputs are also present in `../deliveries/` and do not need another render. Start recovery as actual background work to establish a15-minute sandbox lease, then transfer updates promptly. Never rely on foreground files surviving an idle gap.

The whole-script `higgsedit build` replaces the existing timeline; repeated builds were tested without duplicate clips. Prepared sources invalidate their cache on source/crop/timing/audio-gain changes.
