# Character surface and expression refinement — 2026-09-25

These images are produced by the native Metal renderer from the bundled models.
The office captures use isolated synthetic agents/tasks and send no messages.

## What changed

- Repaired inconsistent triangle orientation and rebuilt coherent normals across
  texture seams. This removes the reversed-lighting patches visible on Legal's
  face, blouse and jacket while preserving the authored garment creases.
- Recovered six genuine high-resolution source atlases and baked portable,
  lossless 2K textures. Source images, UV layouts and output hashes are pinned in
  `assets/character-textures/provenance.json`. Male retains its existing 2K atlas;
  Female shares Design's atlas. Byte, Nyx and Moss keep their distinct recolors.
- Authored seven anatomically calibrated smile profiles covering all eleven
  bundled avatars. Legal has a clearer closed-mouth smile, lifted cheeks and
  relaxed inner brows. Existing open smiles retain their original teeth.
- Preserved character identities, body proportions, skin weights and all 48
  animation clips per model. Custom avatars are not assigned guessed smiles.
- Automatic rendering quality now uses native pixel density during immersion.

## Evidence

`before/` and `after/` contain front and three-quarter closeups of every catalog
entry. Both sets use the same native camera and global environment/key/fill.
Portraits are positioned away from the office's point lights, because the origin
puts a gold desk lamp almost inside the face. `office/` shows actual desk lighting
and conversation poses. Diagnostic directories isolate albedo, normals, culling,
and lighting; those intermediate captures are not the final appearance.

| Character | Before | After |
| --- | --- | --- |
| Legal | [Front](before/legal-front.png) | [Front](after/legal-front.png) |
| Male | [Front](before/male-front.png) | [Front](after/male-front.png) |
| Design | [Front](before/design-front.png) | [Front](after/design-front.png) |
| Finance | [Front](before/finance-front.png) | [Front](after/finance-front.png) |
| Corporate | [Front](before/corporate-front.png) | [Front](after/corporate-front.png) |
| Research | [Front](before/research-front.png) | [Front](after/research-front.png) |
| Developer | [Front](before/developer-front.png) | [Front](after/developer-front.png) |
| Byte | [Front](before/byte-front.png) | [Front](after/byte-front.png) |
| Nyx | [Front](before/nyx-front.png) | [Front](after/nyx-front.png) |
| Moss | [Front](before/moss-front.png) | [Front](after/moss-front.png) |
| Female | [Front](before/female-front.png) | [Front](after/female-front.png) |

The models keep their authored stylized geometry. Recovered textures restore
source detail, not invented detail from upscaling. Windows execution is not
validated on this Mac; the corrected cooked geometry and textures are shared by
both native renderers.

## Validation

- Full macOS desktop application compiled successfully.
- Asset cooker: 41 tests passed, no skips (including the opt-in source audit).
- Final cooked assets passed the native engine and guided-tour suites; all
  eleven entries retain 48 clips, finite skinning and anchored seated poses.
- The guided-tour check also passed UBSan with the final pack.
- Metal API validation rendered 22 final portraits, then the production QML
  conversation flow captured all eleven characters in 69 seconds without errors
  or sending messages. The capture fixture tolerates focus changes while the
  user works in another application; navigation cancellation has separate tests.
- The eleven cooked character files were installed only after hash validation;
  existing office geometry and navigation hashes were preserved.
